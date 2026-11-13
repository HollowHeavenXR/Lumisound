import Foundation
import SwiftUI

/// The full-screen Queue editor.
///
/// Restructured 2026-09: a large Now Playing card at the top (cover,
/// title, live progress, previous / play / next) replaces both the old
/// small hero and the separate pulsing "Now Playing" row; shuffle, repeat,
/// save and cloud-restore moved out of the toolbar into a row of labelled
/// toggles under it; sections get headers with their track count and
/// running time; rows are numbered in play order; and the empty queue
/// offers to shuffle the library.
///
/// Reworked around a real distinction between "Manually Queued" tracks
/// (explicit "Play Next"/"Add to Queue" actions — see `QueueSource`) and the
/// "Up Next" auto-continuation tail (the loaded playlist/album/library list,
/// or Auto-Radio's picks) — rather than one flat, undifferentiated list.
/// Drag-reorder (via the trailing handle, in Edit mode — the same mechanism
/// already used by `PlaylistDetailView`) and swipe-to-remove (available at
/// all times, no Edit mode needed) both operate within their own section, so
/// reordering a manually-queued track can never accidentally spill into the
/// auto-continuation tail or vice versa.
struct QueueView: View {
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var sharePlay: SharePlayCoordinator
    @State private var editMode: EditMode = .inactive
    @State private var isRestoringQueue = false
    @State private var showSaveQueueAlert = false
    @State private var saveQueueName = ""

    private var totalDuration: TimeInterval {
        player.queue.reduce(0) { $0 + $1.duration }
    }

    private func formatDurationLong(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0m" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return "\(h)h \(m)m"
        } else if m > 0 {
            return "\(m)m \(s)s"
        } else {
            return "\(s)s"
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GalleryBackgroundView().ignoresSafeArea()
                queueList
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if !player.queue.isEmpty {
                        Button {
                            withAnimation(LumiMotion.glide) {
                                editMode = editMode == .active ? .inactive : .active
                            }
                        } label: {
                            Text(editMode == .active ? "Done" : "Edit")
                                .fontWeight(.semibold)
                                .foregroundStyle(AppTheme.dynamicAccent)
                        }

                        LumiMenu {
                            Button {
                                saveQueueName = defaultQueueName()
                                showSaveQueueAlert = true
                            } label: {
                                Label("Save as Playlist", systemImage: "square.and.arrow.down")
                            }
                            Button(role: .destructive) {
                                clearQueue()
                            } label: {
                                Label("Clear Queue", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(AppTheme.dynamicAccent)
                        }
                        .accessibilityLabel("More")
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .safeAreaInset(edge: .bottom) {
                MiniPlayerBar()
            }
            .alert("Save Queue as Playlist", isPresented: $showSaveQueueAlert) {
                TextField("Playlist name", text: $saveQueueName)
                Button("Cancel", role: .cancel) {}
                Button("Save") { saveQueueAsPlaylist() }
            } message: {
                Text("Creates a new playlist from all \(player.queue.count) track\(player.queue.count == 1 ? "" : "s") currently in the queue.")
            }
        }
    }

    private var repeatIcon: String {
        switch player.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    // MARK: - Section data

    /// Songs before the current one — shown de-emphasized; tap to jump back,
    /// swipe to remove, but not reorderable (history isn't "up next").
    private var earlierSongs: [Song] {
        guard player.currentIndex > 0, player.currentIndex <= player.queue.count else { return [] }
        return Array(player.queue.prefix(player.currentIndex))
    }

    /// The contiguous auto-continuation tail after the manually-queued block —
    /// exactly the range `AudioPlayerManager.moveAutoQueueItem` reorders, so
    /// local `.onMove` indices from this exact array always land in range.
    private var autoTailSongs: [Song] {
        guard player.repeatMode != .one, !player.queue.isEmpty else { return [] }
        let start = player.manualBlockRange().upperBound
        guard start <= player.queue.count else { return [] }
        return Array(player.queue[start...])
    }

    /// When Repeat All wraps back to the start of the queue, these are the
    /// songs that play after the tail loops — shown read-only in their own
    /// small section (deliberately NOT merged into `autoTailSongs`, which
    /// would desync `.onMove`'s local indices from what
    /// `moveAutoQueueItem` actually reorders).
    private var autoWrapSongs: [Song] {
        guard player.repeatMode == .all, player.currentIndex > 0 else { return [] }
        return Array(player.queue[0..<min(player.currentIndex, player.queue.count)])
    }

    // MARK: - List

    private var queueList: some View {
        List {
            if player.queue.isEmpty {
                emptyState
            } else {
                heroSection
                controlsSection
                contextHeaderSection
                listenTogetherSection
                earlierSection
                manualSection
                autoTailSection
                autoWrapSection
                queueFooter
            }
        }
        // Without an explicit style this defaults to a grouped-card look
        // (gaps between rows showing the gallery background through) — the
        // same "split into disconnected pieces" bug fixed in FavoritesView
        // et al., just via the implicit default instead of an explicit
        // `.insetGrouped`.
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        // Centralizes "smooth animated insertion/removal" for every queue
        // mutation (add/remove/reorder/skip) behind one implicit animation
        // keyed to the queue's identity order, instead of needing every
        // single call site to remember to wrap itself in `withAnimation`.
        .animation(LumiMotion.settle, value: player.queue.map(\.id))
    }

    /// The Now Playing card: blurred backdrop, big cover, title, live
    /// progress and previous / play / next.
    @ViewBuilder
    private var heroSection: some View {
        if let current = player.currentSong {
            ZStack(alignment: .bottom) {
                HeroArtworkBackdrop(song: current, height: 300)

                VStack(spacing: 14) {
                    HStack(alignment: .center, spacing: 16) {
                        ArtworkThumbnail(song: current, size: 118, showsScrim: false)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
                            .shadow(color: .black.opacity(0.45), radius: 14, y: 8)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                if player.isPlaying {
                                    QueuePlayingBars()
                                }
                                Text(player.isPlaying ? "NOW PLAYING" : "PAUSED")
                                    .font(.caption2.weight(.heavy))
                                    .tracking(1.3)
                                    .foregroundStyle(AppTheme.dynamicAccent)
                            }
                            Text(current.displayName)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .lineLimit(2)
                            Text(current.artistName)
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }

                    QueueHeroProgress()

                    HStack(spacing: 36) {
                        heroTransportButton("backward.fill", size: 22, label: "Previous") { player.skipToPrevious() }
                        Button {
                            player.togglePlayPause()
                        } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 58, height: 58)
                                .background(AppTheme.dynamicAccentGradient, in: Circle())
                                .shadow(color: AppTheme.dynamicAccent.opacity(0.45), radius: 12, y: 6)
                                .symbolReplaceTransition()
                        }
                        .buttonStyle(PressableButtonStyle())
                        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                        heroTransportButton("forward.fill", size: 22, label: "Next") { player.userSkipToNext() }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func heroTransportButton(_ icon: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }

    /// Shuffle / Repeat / Save / cloud restore as labelled toggles — they
    /// used to be bare toolbar icons whose state was a colour change.
    private var controlsSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                queueToggle(
                    icon: "shuffle",
                    label: "Shuffle",
                    isOn: player.shuffleEnabled
                ) {
                    withAnimation(LumiMotion.snap) { player.toggleShuffle() }
                }
                queueToggle(
                    icon: repeatIcon,
                    label: repeatLabel,
                    isOn: player.repeatMode != .off
                ) {
                    withAnimation(LumiMotion.snap) { player.cycleRepeatMode() }
                }
                queueToggle(icon: "square.and.arrow.down", label: "Save", isOn: false) {
                    saveQueueName = defaultQueueName()
                    showSaveQueueAlert = true
                }
                if account.isLoggedIn {
                    queueToggle(
                        icon: isRestoringQueue ? "arrow.triangle.2.circlepath" : "icloud.and.arrow.down",
                        label: isRestoringQueue ? "Restoring\u{2026}" : "From Cloud",
                        isOn: false
                    ) {
                        restoreQueueFromCloud()
                    }
                    .disabled(isRestoringQueue)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var repeatLabel: String {
        switch player.repeatMode {
        case .off: return "Repeat"
        case .all: return "Repeat All"
        case .one: return "Repeat One"
        }
    }

    private func queueToggle(icon: String, label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .symbolReplaceTransition()
                Text(label)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(isOn ? .white : AppTheme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                if isOn { Capsule().fill(AppTheme.dynamicAccent) }
            }
            .adaptiveGlass(in: Capsule(), fallback: AppTheme.surface.opacity(isOn ? 0 : 0.7))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(AppTheme.dynamicAccent.opacity(0.15))
                    .frame(width: 110, height: 110)
                Image(systemName: "music.note.list")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(AppTheme.dynamicAccentGradient)
            }
            Text("Nothing queued")
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.textPrimary)
            Text("Play something, or use Play Next and Add to Queue on any song.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if !library.allSongs.isEmpty {
                Button {
                    player.setQueue(library.allSongs.smartShuffled(), startIndex: 0, autoplay: true)
                } label: {
                    Label("Shuffle Your Library", systemImage: "shuffle")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(AppTheme.dynamicAccentGradient, in: Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// "Playing from X" plus how much is left to play.
    private var contextHeaderSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            // The label already reads "Playing from …".
            Text(player.playingFromContextLabel(library: library))
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
            Text(upcomingSummary)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var upcomingSongs: [Song] {
        player.manuallyQueuedUpNext + autoTailSongs
    }

    private var upcomingSummary: String {
        let songs = upcomingSongs
        let time = formatDurationLong(songs.reduce(0) { $0 + ($1.duration.isFinite ? $1.duration : 0) })
        return songs.isEmpty ? "Nothing up next" : "\(songs.count) up next · \(time)"
    }

    /// Shows only during an active Listen Together (SharePlay) session —
    /// participants suggest tracks (via the "Suggest to Group" swipe action
    /// on any row below) and upvote each other's picks; the most-voted one
    /// can be played next with one tap. See `SharePlayCoordinator+Queue.swift`.
    @ViewBuilder
    private var listenTogetherSection: some View {
        if sharePlay.isSessionActive {
            Section {
                if sharePlay.sortedSharedQueue.isEmpty {
                    Text("Swipe a track below and tap \"Suggest\" to add it here for the group to vote on.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(sharePlay.sortedSharedQueue) { item in
                        listenTogetherRow(item)
                    }
                    Button {
                        Task { await sharePlay.playTopSuggestion() }
                    } label: {
                        Label("Play Top Voted Next", systemImage: "play.fill")
                    }
                    .disabled(sharePlay.sortedSharedQueue.isEmpty)
                }
            } header: {
                Label("Listen Together · \(sharePlay.participantCount) here", systemImage: "shareplay")
            }
            .listRowSeparatorTint(AppTheme.surface)
        }
    }

    private func listenTogetherRow(_ item: SharedQueueItem) -> some View {
        let voted = item.voterDeviceIDs.contains(sharePlay.localDeviceID)
        return HStack(spacing: 10) {
            Button {
                withAnimation(LumiMotion.snap) {
                    sharePlay.toggleVote(for: item.id)
                }
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: voted ? "arrow.up.circle.fill" : "arrow.up.circle")
                    Text("\(item.voteCount)")
                        .font(.caption2.monospacedDigit())
                }
                .foregroundStyle(voted ? AppTheme.dynamicAccent : AppTheme.textSecondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(item.artist)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var earlierSection: some View {
        if !earlierSongs.isEmpty {
            Section {
                ForEach(earlierSongs, id: \.id) { song in
                    queueRow(song: song, leadingIcon: nil)
                        .opacity(0.55)
                }
            } header: {
                QueueSectionHeader(icon: "clock.arrow.circlepath", title: "Earlier", songs: earlierSongs)
            }
            .listRowSeparatorTint(AppTheme.surface)
        }
    }

    @ViewBuilder
    private var manualSection: some View {
        let manual = player.manuallyQueuedUpNext
        if !manual.isEmpty {
            Section {
                ForEach(Array(manual.enumerated()), id: \.element.id) { index, song in
                    queueRow(song: song, leadingIcon: nil, position: index + 1)
                }
                .onMove { source, destination in
                    withAnimation(LumiMotion.snap) {
                        player.moveManualQueueItem(from: source, to: destination)
                    }
                }
            } header: {
                QueueSectionHeader(icon: "person.fill.badge.plus", title: "Queued by You", songs: manual)
            }
            .listRowSeparatorTint(AppTheme.surface)
        }
    }

    @ViewBuilder
    private var autoTailSection: some View {
        let auto = autoTailSongs
        // Once per render, not per row — it rebuilds the manual block.
        let manualCount = self.manualCount
        if !auto.isEmpty {
            Section {
                ForEach(Array(auto.enumerated()), id: \.element.id) { index, song in
                    queueRow(song: song, leadingIcon: nil, position: manualCount + index + 1)
                }
                .onMove { source, destination in
                    withAnimation(LumiMotion.snap) {
                        player.moveAutoQueueItem(from: source, to: destination)
                    }
                }
            } header: {
                QueueSectionHeader(
                    icon: player.shuffleEnabled ? "shuffle" : "text.line.first.and.arrowtriangle.forward",
                    title: player.shuffleEnabled ? "Up Next · Shuffled" : "Up Next",
                    songs: auto
                )
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
                QueueSectionHeader(icon: "repeat", title: "Then, From the Top", songs: autoWrapSongs)
            }
            .listRowSeparatorTint(AppTheme.surface)
        }
    }

    /// A single reorderable/removable row shared by every section — tap to
    /// jump to that position in the queue (preserving playback context),
    /// swipe (at any time, no Edit mode needed) to remove.
    private var manualCount: Int { player.manuallyQueuedUpNext.count }

    private func queueRow(song: Song, leadingIcon: String?, position: Int? = nil) -> some View {
        Button {
            jumpTo(song: song)
        } label: {
            HStack(spacing: 8) {
                if let position {
                    Text("\(position)")
                        .font(AppTheme.monoFont(size: 12).weight(.semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(minWidth: 22, alignment: .trailing)
                }
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
        // Each row its own rounded, subtly-elevated card rather than a flat
        // list row blending into the background — the "card stack" reading
        // of the queue this redesign is going for, applied at the row level
        // (not a shared per-section container) so drag-reorder/swipe-remove
        // on individual rows keeps working exactly as before.
        .listRowBackground(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.elevatedSurface.opacity(0.6))
        )
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                withAnimation(LumiMotion.fade(0.22)) {
                    player.removeSong(id: song.id)
                }
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            if sharePlay.isSessionActive {
                Button {
                    sharePlay.suggestTrack(song)
                    ToastCenter.shared.show("Suggested to group", category: .success, icon: "shareplay")
                } label: {
                    Label("Suggest", systemImage: "shareplay")
                }
                .tint(AppTheme.dynamicAccent)
            }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .move(edge: .trailing).combined(with: .opacity)
        ))
    }

    private var queueFooter: some View {
        HStack {
            Image(systemName: "music.note")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
            Text("\(player.queue.count) track\(player.queue.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)

            Text("·")
                .foregroundStyle(AppTheme.textSecondary)
                .font(.caption)

            Image(systemName: "clock")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
            Text(formatDurationLong(totalDuration))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)

            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - Actions

    /// Jumps to a different index within the SAME already-loaded queue —
    /// preserve whatever playlist context it came from (this used to always
    /// clear it, wiping the Now Playing theme memory just by tapping a
    /// different row in Queue).
    private func jumpTo(song: Song) {
        guard let index = player.queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(player.queue, startIndex: index, autoplay: true, playlistID: player.currentPlaylistID)
    }

    private func defaultQueueName() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Queue – \(formatter.string(from: Date()))"
    }

    private func saveQueueAsPlaylist() {
        let name = saveQueueName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !player.queue.isEmpty else { return }
        _ = library.createPlaylist(name: name, songIDs: player.queue.map(\.id))
        ToastCenter.shared.show("Saved \"\(name)\"", category: .success, icon: "checkmark.circle.fill")
    }

    /// Replaces the current queue with the one saved on the server (synced
    /// from another device), keeping playback paused on whatever is now first.
    private func restoreQueueFromCloud() {
        guard !isRestoringQueue else { return }
        isRestoringQueue = true
        Task {
            let songs = await account.fetchQueue(library: library)
            if !songs.isEmpty {
                player.setQueue(songs, startIndex: 0, autoplay: false)
            }
            isRestoringQueue = false
        }
    }

    private func clearQueue() {
        // Remove all items from the queue
        let allIndices = IndexSet(player.queue.indices)
        if !allIndices.isEmpty {
            withAnimation(LumiMotion.fade(0.25)) {
                player.removeFromQueue(at: allIndices)
            }
            ToastCenter.shared.show("Queue cleared", category: .info, icon: "trash")
        }
        editMode = .inactive
    }
}

// MARK: - Section header

private struct QueueSectionHeader: View {
    let icon: String
    let title: String
    let songs: [Song]

    private var durationText: String {
        let total = Int(songs.reduce(0) { $0 + ($1.duration.isFinite ? $1.duration : 0) })
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(max(m, 1))m"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.dynamicAccent)
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppTheme.textPrimary)
                .textCase(nil)
            Spacer()
            Text("\(songs.count) · \(durationText)")
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.textSecondary)
                .textCase(nil)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Hero progress

/// Live position for the Now Playing card. Its own view so only it
/// re-renders on each position tick, not the whole queue list.
private struct QueueHeroProgress: View {
    @EnvironmentObject private var progress: PlaybackProgress

    var body: some View {
        let duration = max(progress.duration, 0.001)
        let fraction = min(max(progress.position / duration, 0), 1)
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.textSecondary.opacity(0.25))
                    Capsule()
                        .fill(AppTheme.dynamicAccentGradient)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 4)
            HStack {
                Text(progress.position.formattedAsMinutesSeconds)
                Spacer()
                Text("-" + max(progress.duration - progress.position, 0).formattedAsMinutesSeconds)
            }
            .font(AppTheme.monoFont(size: 11))
            .foregroundStyle(AppTheme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(progress.position.formattedAsMinutesSeconds) of \(progress.duration.formattedAsMinutesSeconds)")
    }
}

// MARK: - Playing bars

/// Three small bouncing bars next to "NOW PLAYING". 30fps.
private struct QueuePlayingBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: LumiMotion.frame)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .fill(AppTheme.dynamicAccent)
                        .frame(width: 3, height: 4 + 7 * CGFloat(0.5 + 0.5 * sin(t * 6 + Double(i) * 1.3)))
                }
            }
            .frame(height: 11, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}
