import SwiftUI

// MARK: - LyricsSyncEditorView

/// A tap-to-sync lyric timing editor.
///
/// Usage:
///  - If the current song has lyrics (already loaded as `[LrcLine]` from
///    NowPlayingView's `loadLyrics()` result), those lines are passed in.
///  - Tapping a line while the song plays records the current playback position
///    (from `progress`, see `PlaybackProgress`) as that line's timestamp.
///  - The "Save" button writes a `.lrc` file to
///    `Documents/Lyrics/{songID}.lrc` in standard LRC format.
///  - If `initialLines` is empty, a plain-text paste area is shown first so the
///    user can supply raw lyric text before timing.
struct LyricsSyncEditorView: View {

    // Lines already known from NowPlayingView's lyrics loader.
    // Pass `[]` when no lyrics are available yet.
    let initialLines: [LrcLine]

    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var progress: PlaybackProgress
    @Environment(\.dismiss) private var dismiss

    // MARK: State

    /// Editable rows: (original text, user-assigned timestamp or nil)
    @State private var rows: [LyricRow] = []

    /// Paste area for when no lyrics are provided
    @State private var pastedText: String = ""
    @State private var showPasteView: Bool = false

    /// Save feedback
    @State private var saveStatus: SaveStatus = .idle

    /// Haptic
    private let tapHaptic = UIImpactFeedbackGenerator(style: .light)

    // MARK: Init

    init(initialLines: [LrcLine]) {
        self.initialLines = initialLines
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Group {
                if showPasteView {
                    pasteView
                } else {
                    editorView
                }
            }
            .navigationTitle("Lyrics Sync Editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(AppTheme.textSecondary)
                }
                if !showPasteView {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        saveButton
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
        }
        .onAppear { setup() }
        .preferredColorScheme(.dark)
    }

    // MARK: - Setup

    private func setup() {
        tapHaptic.prepare()
        if initialLines.isEmpty {
            showPasteView = true
        } else {
            rows = initialLines.map { LyricRow(text: $0.text, timestamp: $0.time > 0 ? $0.time : nil) }
        }
    }

    // MARK: - Paste view (no lyrics available)

    private var pasteView: some View {
        VStack(spacing: 16) {
            Text("No lyrics found for this song.\nPaste the lyrics below — one line per row.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 8)

            TextEditor(text: $pastedText)
                .font(.body)
                .foregroundStyle(AppTheme.textPrimary)
                .scrollContentBackground(.hidden)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 16)

            Button {
                loadPastedLyrics()
            } label: {
                Text("Use These Lyrics")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.dynamicAccent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
            .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(.bottom, 16)
        }
        .background(Color.black.ignoresSafeArea())
    }

    private func loadPastedLyrics() {
        let lines = pastedText
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        rows = lines.map { LyricRow(text: $0, timestamp: nil) }
        withAnimation(LumiMotion.glide) { showPasteView = false }
    }

    // MARK: - Editor view

    private var editorView: some View {
        VStack(spacing: 0) {
            // Playback controls strip
            controlStrip
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(AppTheme.surface)

            Divider().background(AppTheme.elevatedSurface)

            // Lyrics list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows.indices, id: \.self) { idx in
                            lyricRow(index: idx, proxy: proxy)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: currentHighlightIndex) { newIdx in
                    guard let idx = newIdx else { return }
                    withAnimation(LumiMotion.fade(0.3)) {
                        proxy.scrollTo(idx, anchor: .center)
                    }
                }
            }

            // Action bar
            actionBar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(AppTheme.surface)
        }
    }

    // MARK: - Control strip

    private var controlStrip: some View {
        HStack(spacing: 16) {
            // Play / Pause
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(AppTheme.dynamicAccent)
            }
            .buttonStyle(.plain)

            // Current position
            Text(formatTime(progress.position))
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .monospacedDigit()
                .frame(minWidth: 56, alignment: .leading)

            Text("/ \(formatTime(progress.duration))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(AppTheme.textSecondary)
                .monospacedDigit()

            Spacer()

            // Tap hint
            Label("Tap a line to stamp", systemImage: "hand.tap")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    // MARK: - Individual lyric row

    @ViewBuilder
    private func lyricRow(index: Int, proxy: ScrollViewProxy) -> some View {
        let isCurrent = index == currentHighlightIndex
        let row = rows[index]

        HStack(spacing: 12) {
            // Timestamp badge
            Text(row.timestamp.map { formatTime($0) } ?? "  --  ")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(row.timestamp != nil ? AppTheme.dynamicAccent : AppTheme.textSecondary.opacity(0.5))
                .frame(width: 54, alignment: .trailing)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    row.timestamp != nil
                        ? AppTheme.dynamicAccent.opacity(0.15)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )

            // Lyric text
            Text(row.text.isEmpty ? "·" : row.text)
                .font(isCurrent ? .body.weight(.semibold) : .body)
                .foregroundStyle(isCurrent ? .white : AppTheme.textSecondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .scaleEffect(isCurrent ? 1.03 : 1.0, anchor: .leading)
                .animation(LumiMotion.snap, value: isCurrent)

            // Clear individual stamp
            if row.timestamp != nil {
                Button {
                    rows[index].timestamp = nil
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(AppTheme.textSecondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isCurrent ? AppTheme.dynamicAccent.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            tapHaptic.impactOccurred()
            rows[index].timestamp = progress.position
        }
        .id(index)
        .animation(LumiMotion.fade(0.15), value: isCurrent)
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 14) {
            // Reset all timestamps
            Button {
                withAnimation(LumiMotion.glide) {
                    for i in rows.indices { rows[i].timestamp = nil }
                }
            } label: {
                Label("Reset All", systemImage: "arrow.counterclockwise")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(AppTheme.elevatedSurface, in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            // Save status message
            if saveStatus != .idle {
                Text(saveStatus == .saved ? "Saved!" : "Save failed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(saveStatus == .saved ? AppTheme.success : AppTheme.error)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Save button (toolbar)

    private var saveButton: some View {
        Button {
            saveLrcFile()
        } label: {
            Text("Save")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.dynamicAccent)
        }
        .disabled(rows.allSatisfy { $0.timestamp == nil })
    }

    // MARK: - Current highlight index

    private var currentHighlightIndex: Int? {
        guard !rows.isEmpty else { return nil }
        let pos = progress.position
        var result: Int? = nil
        for (i, row) in rows.enumerated() {
            guard let ts = row.timestamp else { continue }
            if ts <= pos { result = i } else { break }
        }
        return result
    }

    // MARK: - Save LRC

    private func saveLrcFile() {
        guard let song = player.currentSong else { return }

        var lrcContent = ""

        // Optional header tags
        let title  = song.displayName
        let artist = song.artistName
        if !title.isEmpty  { lrcContent += "[ti:\(title)]\n" }
        if !artist.isEmpty { lrcContent += "[ar:\(artist)]\n" }
        lrcContent += "\n"

        // Stamped lines only, sorted by timestamp
        let stamped = rows
            .compactMap { row -> (TimeInterval, String)? in
                guard let ts = row.timestamp else { return nil }
                return (ts, row.text)
            }
            .sorted { $0.0 < $1.0 }

        for (ts, text) in stamped {
            lrcContent += "[\(lrcTimestamp(ts))]\(text)\n"
        }

        guard !stamped.isEmpty else { return }

        do {
            let lyricsDir = try lyricsDirectory()
            let filename  = sanitizeFilename(song.id) + ".lrc"
            let fileURL   = lyricsDir.appendingPathComponent(filename)
            try lrcContent.write(to: fileURL, atomically: true, encoding: .utf8)
            withAnimation(LumiMotion.glide) { saveStatus = .saved }
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                withAnimation(LumiMotion.glide) { saveStatus = .idle }
            }
        } catch {
            withAnimation(LumiMotion.glide) { saveStatus = .failed }
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                withAnimation(LumiMotion.glide) { saveStatus = .idle }
            }
        }
    }

    // MARK: - Helpers

    /// Returns (and creates if needed) Documents/Lyrics/
    private func lyricsDirectory() throws -> URL {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "LyricsSyncEditorView", code: 1, userInfo: [NSLocalizedDescriptionKey: "Documents directory unavailable"])
        }
        let dir  = docs.appendingPathComponent("Lyrics", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Formats a TimeInterval as the LRC tag `MM:SS.xx`
    private func lrcTimestamp(_ time: TimeInterval) -> String {
        let totalSeconds = max(0, time)
        let minutes      = Int(totalSeconds / 60)
        let seconds      = Int(totalSeconds) % 60
        let hundredths   = Int((totalSeconds - Double(Int(totalSeconds))) * 100)
        return String(format: "%02d:%02d.%02d", minutes, seconds, hundredths)
    }

    /// Formats a TimeInterval for display as `M:SS`
    private func formatTime(_ time: TimeInterval) -> String {
        time.formattedAsMinutesSeconds
    }

    /// Strips filesystem-illegal characters from a filename
    private func sanitizeFilename(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\*?\"<>|")
        return raw.components(separatedBy: illegal).joined(separator: "_")
    }
}

// MARK: - Supporting Types

private struct LyricRow: Identifiable {
    let id = UUID()
    var text: String
    var timestamp: TimeInterval?
}

private enum SaveStatus: Equatable {
    case idle, saved, failed
}
