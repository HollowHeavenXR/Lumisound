import SwiftUI
import UIKit

// MARK: - NowPlayingView Queue Preview (compact, embedded card)

extension NowPlayingView {

    // MARK: - Queue Data

    /// Songs explicitly queued by the user ("Play Next"/"Add to Queue"),
    /// still to come — see `QueueSource` / `AudioPlayerManager+Queue`.
    var manualUpNextSongs: [Song] { player.manuallyQueuedUpNext }

    /// Songs that will play next as part of the natural playback context
    /// (the loaded playlist/album/library list, or Auto-Radio's picks),
    /// after the manually-queued block is exhausted — includes the Repeat
    /// All wraparound back to the top of the queue.
    var autoUpNextSongs: [Song] { player.autoContinuationUpNext }

    /// Every upcoming song, manual + auto, in play order.
    var upNextSongs: [Song] { manualUpNextSongs + autoUpNextSongs }

    private var queuePreviewContextLabel: String { player.playingFromContextLabel(library: library) }

    /// The compact "Up Next" card shown in the segmented panel picker's
    /// "Queue" tab. Collapsible via the existing `showQueuePreview`
    /// AppStorage flag (synced across devices — see `AccountService+Sync`),
    /// same contract as before this rework, just with genuinely richer
    /// content: a persistent "Playing from X" context label, the current
    /// track highlighted, and manually-queued vs. auto-continuation tracks
    /// split into their own labeled sections instead of one undifferentiated
    /// horizontal strip.
    ///
    /// Deliberately a fast glance/jump/remove surface, not a drag-and-drop
    /// editor — this lives inside `NowPlayingView`'s outer `ScrollView`
    /// (see `NowPlayingView+ScrollContent`), and SwiftUI's native
    /// `List`-based reorder handles don't play well nested inside another
    /// scroll view. Full drag reorder lives in `QueuePageView` below (built
    /// for exactly this — see its own doc comment) and in the standalone
    /// `QueueView` screen.
    var queuePreviewSection: some View {
        DisclosureGroup(
            isExpanded: $showQueuePreview,
            content: {
                VStack(alignment: .leading, spacing: 10) {
                    Text(queuePreviewContextLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)

                    if player.queue.isEmpty {
                        Text("Queue is empty")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 12)
                    } else {
                        compactUpNextList
                    }
                }
                .padding(.top, 6)
            },
            label: {
                HStack(spacing: 6) {
                    Text("Up Next")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    if player.upNextCount > 0 {
                        Text("\(player.upNextCount)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.dynamicAccent, in: Capsule())
                    }
                    if player.shuffleEnabled {
                        Image(systemName: "shuffle")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.dynamicAccent)
                    }
                    Spacer()
                    Text("\(player.queue.count) tracks")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
        )
        .tint(AppTheme.dynamicAccent)
        .panelStyle()
    }

    @ViewBuilder
    private var compactUpNextList: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let current = player.currentSong {
                compactRow(song: current, isCurrent: true)
            }
            // Read each list once: both copy the rest of the queue, which
            // can be the whole library.
            let manual = manualUpNextSongs
            let auto = autoUpNextSongs
            if !manual.isEmpty {
                compactSectionLabel("Manually Queued", icon: "person.fill.badge.plus")
                ForEach(manual.prefix(10)) { song in
                    compactRow(song: song, isCurrent: false)
                }
                if manual.count > 10 {
                    Text("+ \(manual.count - 10) more — see full queue")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.leading, 4)
                }
            }
            if !auto.isEmpty {
                compactSectionLabel("Up Next", icon: nil)
                ForEach(auto.prefix(10)) { song in
                    compactRow(song: song, isCurrent: false)
                }
                if auto.count > 10 {
                    Text("+ \(auto.count - 10) more — see full queue")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.leading, 4)
                }
            }
        }
    }

    private func compactSectionLabel(_ text: String, icon: String?) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2)
            }
            Text(text.uppercased())
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(AppTheme.textSecondary)
        .padding(.top, 4)
    }

    private func compactRow(song: Song, isCurrent: Bool) -> some View {
        Button {
            guard let idx = player.queue.firstIndex(where: { $0.id == song.id }) else { return }
            player.setQueue(player.queue, startIndex: idx, autoplay: true, playlistID: player.currentPlaylistID)
        } label: {
            HStack(spacing: 10) {
                ArtworkThumbnail(song: song, size: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        if isCurrent {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(AppTheme.dynamicAccent, lineWidth: 2)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.displayName)
                        .font(.subheadline)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .foregroundStyle(isCurrent ? AppTheme.dynamicAccent : AppTheme.textPrimary)
                        .lineLimit(1)
                    Text(song.artistName)
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if !isCurrent {
                    Button {
                        withAnimation(LumiMotion.fade(0.2)) {
                            player.removeSong(id: song.id)
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(AppTheme.textSecondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .buttonStyle(.plain)
        .transition(.asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .opacity
        ))
    }
}

// MARK: - QueuePageView (paging-ready full "Up Next" page)

/// A full, standalone "Up Next" screen — genuine drag reorder (`.onMove`, in
/// Edit mode) and swipe-to-remove (`.swipeActions`, always available), the
/// same proven mechanism as `QueueView`, just without `QueueView`'s own
/// `NavigationStack`/toolbar chrome.
///
/// This is a plain `View` (not an extension on `NowPlayingView`) specifically
/// so it can carry its own `@State` — extensions can't add stored properties,
/// and `NowPlayingView.swift` itself belongs to the sibling "Now Playing
/// redesign" workstream, not this one. Reads `AudioPlayerManager` and
/// `LibraryManager` via `@EnvironmentObject`, so it picks up whatever's
/// already in the environment when embedded inside `NowPlayingView` — no
/// extra wiring needed beyond instantiating `QueuePageView()`.
///
/// Intended use: the second page of a paged, swipeable Now Playing sheet
/// (`TabView` + `.tabViewStyle(.page(indexDisplayMode: .always))`), sitting
/// alongside the main player page with a dot indicator between them — the
/// way a YouTube-Music-style player pages between "Player" and "Up Next".
/// See this workstream's final summary for exactly how the Now Playing
/// redesign workstream should wire this in.
struct QueuePageView: View {
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var library: LibraryManager

    @State private var editMode: EditMode = .inactive
    @State private var nowPlayingPulse = false
    @State private var showSaveAlert = false
    @State private var saveName = ""

    private var autoTailSongs: [Song] {
        guard player.repeatMode != .one, !player.queue.isEmpty else { return [] }
        let start = player.manualBlockRange().upperBound
        guard start <= player.queue.count else { return [] }
        return Array(player.queue[start...])
    }

    private var autoWrapSongs: [Song] {
        guard player.repeatMode == .all, player.currentIndex > 0 else { return [] }
        return Array(player.queue[0..<min(player.currentIndex, player.queue.count)])
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            List {
                if player.queue.isEmpty {
                    Text("Queue is empty")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 32)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    nowPlayingSection
                    manualSection
                    autoTailSection
                    autoWrapSection
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .environment(\.editMode, $editMode)
            .animation(LumiMotion.settle, value: player.queue.map(\.id))
        }
        .alert("Save Queue as Playlist", isPresented: $showSaveAlert) {
            TextField("Playlist name", text: $saveName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { saveQueueAsPlaylist() }
        } message: {
            Text("Creates a new playlist from all \(player.queue.count) track\(player.queue.count == 1 ? "" : "s") currently in the queue.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(player.playingFromContextLabel(library: library))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text("\(player.queue.count) track\(player.queue.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            Button {
                saveName = defaultQueueName()
                showSaveAlert = true
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.dynamicAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(AppTheme.dynamicAccent.opacity(0.15), in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            if !player.queue.isEmpty {
                Button {
                    withAnimation(LumiMotion.glide) { editMode = editMode == .active ? .inactive : .active }
                } label: {
                    Text(editMode == .active ? "Done" : "Reorder")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.dynamicAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(AppTheme.dynamicAccent.opacity(0.15), in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Sections

    @ViewBuilder
    private var nowPlayingSection: some View {
        if let current = player.currentSong {
            Section {
                SongRow(song: current, isCurrent: true)
                    .padding(.vertical, 2)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AppTheme.dynamicAccent.opacity(nowPlayingPulse ? 0.20 : 0.09))
                    )
                    .onAppear {
                        withAnimation(LumiMotion.drift(1.1)) {
                            nowPlayingPulse = true
                        }
                    }
            } header: {
                Text("Now Playing")
            }
            .listRowSeparatorTint(AppTheme.surface)
        }
    }

    @ViewBuilder
    private var manualSection: some View {
        let manual = player.manuallyQueuedUpNext
        if !manual.isEmpty {
            Section {
                ForEach(manual, id: \.id) { song in
                    queueRow(song: song, leadingIcon: "person.fill")
                }
                .onMove { source, destination in
                    withAnimation(LumiMotion.snap) {
                        player.moveManualQueueItem(from: source, to: destination)
                    }
                }
            } header: {
                Label("Manually Queued", systemImage: "person.fill.badge.plus")
            }
            .listRowSeparatorTint(AppTheme.surface)
        }
    }

    @ViewBuilder
    private var autoTailSection: some View {
        let auto = autoTailSongs
        if !auto.isEmpty {
            Section {
                ForEach(auto, id: \.id) { song in
                    queueRow(song: song, leadingIcon: nil)
                }
                .onMove { source, destination in
                    withAnimation(LumiMotion.snap) {
                        player.moveAutoQueueItem(from: source, to: destination)
                    }
                }
            } header: {
                HStack(spacing: 4) {
                    Text("Up Next")
                    if player.shuffleEnabled {
                        Image(systemName: "shuffle")
                    }
                }
            }
            .listRowSeparatorTint(AppTheme.surface)
        }
    }

    @ViewBuilder
    private var autoWrapSection: some View {
        if !autoWrapSongs.isEmpty {
            Section {
                ForEach(autoWrapSongs, id: \.id) { song in
                    queueRow(song: song, leadingIcon: nil)
                        .opacity(0.7)
                }
            } header: {
                Label("Then, From the Top", systemImage: "repeat")
            }
            .listRowSeparatorTint(AppTheme.surface)
        }
    }

    private func queueRow(song: Song, leadingIcon: String?) -> some View {
        Button {
            guard let idx = player.queue.firstIndex(where: { $0.id == song.id }) else { return }
            player.setQueue(player.queue, startIndex: idx, autoplay: true, playlistID: player.currentPlaylistID)
        } label: {
            HStack(spacing: 8) {
                if let leadingIcon {
                    Image(systemName: leadingIcon)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.dynamicAccent)
                        .frame(width: 14)
                }
                SongRow(song: song, isCurrent: false)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                withAnimation(LumiMotion.fade(0.22)) {
                    player.removeSong(id: song.id)
                }
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .move(edge: .trailing).combined(with: .opacity)
        ))
    }

    // MARK: - Actions

    private func defaultQueueName() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Queue – \(formatter.string(from: Date()))"
    }

    private func saveQueueAsPlaylist() {
        let name = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !player.queue.isEmpty else { return }
        _ = library.createPlaylist(name: name, songIDs: player.queue.map(\.id))
        ToastCenter.shared.show("Saved \"\(name)\"", category: .success, icon: "checkmark.circle.fill")
    }
}
