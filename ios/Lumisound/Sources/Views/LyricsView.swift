import SwiftUI

struct LyricsView: View {
    let lines: [LrcLine]
    let currentPosition: TimeInterval
    let isPlaying: Bool

    /// Whether these lyrics carry real timing at all.
    ///
    /// Unsynced lyrics (a plain-text result from LRCLIB's `plainLyrics`, from
    /// lyrics.ovh, an imported `.txt`, or words Aria heard but could not time)
    /// are represented as `LrcLine`s that all share `time: 0`, and three call
    /// sites' comments claimed that made them "display together" as a static
    /// block. It did not. `currentLineIndex` looked for the last line at or
    /// before the current position, and when every line sits at 0, every line
    /// qualifies — so the answer was always the FINAL line. The highlight sat
    /// pinned to the bottom of the lyrics from the first second of the track and
    /// auto-scrolled there, never responding to the music, a seek, or a pause.
    /// Which is indistinguishable, to look at, from lyrics that simply do not
    /// sync.
    ///
    /// A single timestamp of 0 is normal for a synced set (a track whose first
    /// line lands at 0.00), so this asks whether ANY line is timed rather than
    /// whether the first one is.
    private var isSynced: Bool {
        lines.contains { $0.time > 0 }
    }

    private var currentLineIndex: Int? {
        // Nothing is "current" without timing — see `isSynced`.
        guard isSynced else { return nil }
        // Last line whose timestamp is <= currentPosition
        var result: Int? = nil
        for (index, line) in lines.enumerated() {
            if line.time <= currentPosition {
                result = index
            } else {
                break
            }
        }
        return result
    }

    var body: some View {
        if lines.isEmpty {
            emptyState
        } else {
            lyricsScroll
        }
    }

    private var emptyState: some View {
        Text("No lyrics available")
            .font(.subheadline)
            .foregroundStyle(AppTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }

    private var lyricsScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 12) {
                    if !isSynced {
                        // Said plainly, because the alternative is a user
                        // watching lyrics that never move and concluding the
                        // syncing is broken — which is exactly how this was
                        // reported. These lyrics have no timing to follow.
                        Label("These lyrics aren't time-synced", systemImage: "text.alignleft")
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.bottom, 4)
                    }
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        lyricLine(line: line, isCurrent: index == currentLineIndex)
                            .id(line.id)
                    }
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 8)
            }
            .onChange(of: currentLineIndex) { newIndex in
                scrollToCurrentLine(proxy: proxy, index: newIndex, animated: isPlaying)
            }
            .onChange(of: isPlaying) { playing in
                // Re-anchor to the line matching the *actual* current position the
                // moment playback resumes, without animation — any scroll animation
                // left over from before the pause (or queued while paused) would
                // otherwise keep interpolating against a now-stale target and the
                // highlighted line would visibly drift from the real playtime.
                if playing {
                    scrollToCurrentLine(proxy: proxy, index: currentLineIndex, animated: false)
                }
            }
            .onAppear {
                // Land on the correct line immediately when the lyrics panel first
                // appears (e.g. opening Lyrics mid-track) instead of animating a
                // long scroll from the top.
                scrollToCurrentLine(proxy: proxy, index: currentLineIndex, animated: false)
            }
        }
    }

    private func scrollToCurrentLine(proxy: ScrollViewProxy, index: Int?, animated: Bool) {
        guard let idx = index, lines.indices.contains(idx) else { return }
        if animated {
            withAnimation(LumiMotion.fade(0.35)) {
                proxy.scrollTo(lines[idx].id, anchor: .center)
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(lines[idx].id, anchor: .center)
            }
        }
    }

    private func lyricLine(line: LrcLine, isCurrent: Bool) -> some View {
        Text(line.text.isEmpty ? "·" : line.text)
            .font(isCurrent ? .body.weight(.semibold) : .body)
            .foregroundStyle(isCurrent ? AppTheme.dynamicAccent : AppTheme.textSecondary)
            .multilineTextAlignment(.center)
            .scaleEffect(isCurrent ? 1.06 : 1.0)
            .animation(LumiMotion.snap, value: isCurrent)
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(Rectangle())
    }
}
