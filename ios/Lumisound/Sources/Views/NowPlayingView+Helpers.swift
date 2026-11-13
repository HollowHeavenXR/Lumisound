import SwiftUI
import UIKit

extension NowPlayingView {

    // MARK: - Helpers

    func labeledSlider(
        label: String,
        valueText: String,
        value: Binding<Float>,
        range: ClosedRange<Float>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text(valueText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Slider(value: value, in: range)
                .tint(AppTheme.dynamicAccent)
        }
    }

    func audioBinding(_ keyPath: WritableKeyPath<AudioSettings, Float>) -> Binding<Float> {
        Binding {
            player.audioSettings[keyPath: keyPath]
        } set: { value in
            var settings = player.audioSettings
            settings[keyPath: keyPath] = value
            player.audioSettings = settings
        }
    }

    func formatTime(_ time: TimeInterval) -> String {
        time.formattedAsMinutesSeconds
    }

    func triggerTrackChangeAnimation() {
        // Fade/shrink the *current* artwork out first — only swap the `.id()` (which
        // tears down and recreates the artwork view) once it's invisible. Updating the
        // ID immediately used to pop the new artwork in instantly before the fade-out
        // animation had a chance to play, producing a jarring flash on every transition
        // (and especially during crossfade, where the swap happens mid-playback).
        withAnimation(LumiMotion.glide(0.15)) {
            artworkOpacity = 0
            artworkScale = 0.92
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            artworkAnimationID = player.currentSong?.id ?? UUID().uuidString
            withAnimation(LumiMotion.settle) {
                artworkOpacity = 1
                artworkScale = 1.0
            }
        }
    }

    func triggerTrackInfoAnimation() {
        // Snap the info out (invisible, shifted down), then animate back in
        trackInfoVisible = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            trackInfoVisible = true
        }
    }

    /// Records what was actually loaded, so a "lyrics aren't syncing" report is
    /// diagnosable from the field.
    ///
    /// This pipeline had no logging at all, which is why the two real defects
    /// behind that report survived so long: untimed lyrics pinning the highlight
    /// to the last line (see `LyricsView.isSynced`) and Aria returning
    /// timestamps that ran past the end of the track (see
    /// `lyrics_ai.timings_are_plausible` on the bridge) both present identically
    /// on screen — lyrics that ignore the music — and neither left a trace.
    /// `lastTime` against `duration` is the specific signal that separates them:
    /// a last timestamp beyond the track's length is provably bad timing, and
    /// all-zero timestamps mean there is no timing at all.
    func logLyricsLoaded(source: String, song: Song) {
        let timed = lyricsLines.filter { $0.time > 0 }.count
        appLog(
            "loadLyrics: \(lyricsLines.count) line(s) from \(source) for \"\(song.displayName)\" — "
            + "timed: \(timed)/\(lyricsLines.count), "
            + "lastTime: \(String(format: "%.1f", lyricsLines.last?.time ?? 0))s, "
            + "duration: \(String(format: "%.1f", song.duration))s",
            category: "lyrics"
        )
    }

    func loadLyrics() {
        guard let song = player.currentSong else { lyricsLines = []; return }

        // 1. User-synced lyrics saved via the in-app Lyrics Sync Editor — these
        //    represent the user's own deliberate timing work, so they take
        //    priority over a generic sidecar file or a remote guess.
        if let content = try? String(contentsOf: syncedLyricsURL(for: song), encoding: .utf8) {
            lyricsLines = LrcParser.parse(content)
            logLyricsLoaded(source: "user-synced/aria", song: song)
            return
        }

        // 2. Sidecar .lrc file next to the audio file
        if let url = song.url {
            let lrcURL = url.deletingPathExtension().appendingPathExtension("lrc")
            if let content = try? String(contentsOf: lrcURL, encoding: .utf8) {
                lyricsLines = LrcParser.parse(content)
                logLyricsLoaded(source: "sidecar .lrc", song: song)
                return
            }
        }

        // 2b. A plain (unsynced) .txt file the user imported via "Import
        // Lyrics File" (see importLyricsFile(from:) below) for a track
        // whose lyrics have no timestamps to sync — LrcParser can't
        // produce anything useful from untimed text (every line requires
        // at least one [mm:ss] tag to survive parsing), so this is read
        // as raw lines directly instead, same shape fetchLyricsOVH already
        // uses for its own untimed results (time: 0). `LyricsView` treats an
        // all-zero set as unsynced and renders it as a static, non-highlighted
        // block — see its `isSynced`. That was what this comment always claimed
        // happened, but until that check existed it did not: every line counted
        // as "already reached", so the highlight pinned itself to the last line
        // and auto-scrolled to the bottom for the whole track.
        if let content = try? String(contentsOf: importedPlainLyricsURL(for: song), encoding: .utf8) {
            lyricsLines = content.components(separatedBy: .newlines)
                .map { LrcLine(time: 0, text: $0) }
                .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            logLyricsLoaded(source: "imported plain .txt", song: song)
            return
        }

        // 3. LRCLIB — free, open lyrics database with synced LRC support
        //    Falls back to LyricsOVH if LRCLIB has no synced version.
        // Clear any lyrics left over from the previous track *before* kicking
        // off the remote fetch — otherwise the previous song's lyrics stay on
        // screen (and scroll/highlight against the new song's `progress`)
        // until the network call resolves, which looks like "wrong track"
        // lyrics for the new song.
        lyricsLines = []
        let songID = song.id
        Task {
            let title  = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = song.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }

            // Skipping tracks fires loadLyrics() again before the previous
            // fetch resolves — an in-flight fetch for a now-stale song can
            // land after the new one and overwrite the correct lyrics with
            // the wrong song's. Bail if the user has moved on by the time
            // each remote call resolves. `currentSong` is main-actor isolated,
            // so every check has to hop over via MainActor.run.

            // LRCLIB: returns synced LRC if available
            if let lines = await fetchLRCLIB(title: title, artist: artist, duration: song.duration), !lines.isEmpty {
                await MainActor.run {
                    if player.currentSong?.id == songID {
                        lyricsLines = lines
                        logLyricsLoaded(source: "LRCLIB", song: song)
                    }
                }
                return
            }
            guard await MainActor.run(body: { player.currentSong?.id == songID }) else { return }

            // LyricsOVH: plain text fallback (no timestamps — shown as static block)
            if let lines = await fetchLyricsOVH(title: title, artist: artist), !lines.isEmpty {
                await MainActor.run {
                    if player.currentSong?.id == songID {
                        lyricsLines = lines
                        logLyricsLoaded(source: "lyrics.ovh (untimed)", song: song)
                    }
                }
            }
        }
    }

    /// Path where `LyricsSyncEditorView` saves user-synced lyrics: `Documents/Lyrics/{songID}.lrc`.
    /// Filename sanitization must match `LyricsSyncEditorView.sanitizeFilename` exactly,
    /// or saved files silently become unreadable here.
    func syncedLyricsURL(for song: Song) -> URL {
        let illegal  = CharacterSet(charactersIn: "/:\\*?\"<>|")
        let filename = song.id.components(separatedBy: illegal).joined(separator: "_") + ".lrc"
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lyrics", isDirectory: true)
            .appendingPathComponent(filename)
    }

    /// Companion to `syncedLyricsURL(for:)` for a track whose imported
    /// lyrics file had no LRC timestamps — same directory/sanitization,
    /// just `.txt` instead of `.lrc` so the two never collide for the same
    /// song (see `importLyricsFile(from:)` and `loadLyrics()`'s step 2b).
    func importedPlainLyricsURL(for song: Song) -> URL {
        let illegal  = CharacterSet(charactersIn: "/:\\*?\"<>|")
        let filename = song.id.components(separatedBy: illegal).joined(separator: "_") + ".txt"
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lyrics", isDirectory: true)
            .appendingPathComponent(filename)
    }

    /// "Open up custom lyrics files injecting" — imports a user-picked
    /// .lrc/.txt file (via the system document browser, see
    /// `showLyricsFileImporter` on `NowPlayingView`) as this track's lyrics.
    /// Detects which of the two it actually got by trying to parse LRC
    /// timestamps out of it rather than trusting the file extension alone
    /// — a renamed .txt full of real `[mm:ss]` tags still gets synced
    /// playback, and a mislabeled .lrc with no tags still displays as plain
    /// text instead of silently showing nothing.
    func importLyricsFile(from pickedURL: URL) {
        guard let song = player.currentSong else {
            lyricsImportError = "No track is currently playing to attach these lyrics to."
            return
        }

        // `.fileImporter` hands back a URL outside the app's own sandbox —
        // reading it requires bracketing the read in a security-scoped
        // resource access, matching every other document-picker import
        // path elsewhere in this app.
        let didStartAccess = pickedURL.startAccessingSecurityScopedResource()
        defer { if didStartAccess { pickedURL.stopAccessingSecurityScopedResource() } }

        guard let content = (try? String(contentsOf: pickedURL, encoding: .utf8))
            ?? (try? String(contentsOf: pickedURL, encoding: .isoLatin1))
        else {
            lyricsImportError = "Couldn't read that file as text."
            return
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lyricsImportError = "That file appears to be empty."
            return
        }

        do {
            let lyricsDir = syncedLyricsURL(for: song).deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: lyricsDir.path) {
                try FileManager.default.createDirectory(at: lyricsDir, withIntermediateDirectories: true)
            }

            if !LrcParser.parse(content).isEmpty {
                // Real synced content — save as this track's .lrc, and clear
                // any stale plain-text import left over from a previous
                // attempt so loadLyrics() can't find both and pick the
                // wrong one on some future call.
                try content.write(to: syncedLyricsURL(for: song), atomically: true, encoding: .utf8)
                try? FileManager.default.removeItem(at: importedPlainLyricsURL(for: song))
            } else {
                // No LRC tags found anywhere in the file — treat as plain
                // unsynced lyrics instead of silently discarding it.
                try content.write(to: importedPlainLyricsURL(for: song), atomically: true, encoding: .utf8)
                try? FileManager.default.removeItem(at: syncedLyricsURL(for: song))
            }
            loadLyrics()
        } catch {
            lyricsImportError = "Couldn't save that file: \(error.localizedDescription)"
        }
    }

    /// Has Aria Lumi listen to the current track and generate (or, if
    /// `lyricsLines` already has something from a remote fetch/import,
    /// correct and re-time) synced lyrics for it — see
    /// `StreamingService.transcribeLyrics`. The result is written to the
    /// exact same file the manual Sync Editor saves to
    /// (`syncedLyricsURL(for:)`), so once generated it behaves identically
    /// to a user's own hand-synced lyrics: it wins over any future remote
    /// fetch, and remains editable in the Sync Editor if a line or two
    /// needs a manual nudge afterward.
    func generateLyricsWithAria() {
        guard let song = player.currentSong else {
            lyricsImportError = "No track is currently playing."
            return
        }
        guard let streaming = StreamingService.shared, let token = account.token else {
            lyricsImportError = "Sign in to use Aria's lyrics transcription."
            return
        }
        guard !isGeneratingLyrics else { return }
        isGeneratingLyrics = true

        // Whatever untimed text is already on screen becomes Aria's
        // starting point — the actual "cross-check the words against what's
        // playing" step, not a fresh blind transcription every time.
        let hint = lyricsLines.isEmpty ? nil : lyricsLines.map(\.text).joined(separator: "\n")
        let songID = song.id

        Task { @MainActor in
            defer { isGeneratingLyrics = false }
            do {
                let result = try await streaming.transcribeLyrics(for: song, token: token, hintLyrics: hint)
                // The user may have skipped tracks while this was in flight —
                // don't clobber whatever's now showing with a stale result.
                guard player.currentSong?.id == songID else { return }

                if result.instrumental || (result.lrc.isEmpty && result.plain.isEmpty) {
                    ToastCenter.shared.show(
                        result.instrumental ? "Aria didn't find any lyrics — looks instrumental" : "Aria couldn't make out clear lyrics for this track",
                        category: .info, icon: "waveform"
                    )
                    return
                }

                let lyricsDir = syncedLyricsURL(for: song).deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: lyricsDir.path) {
                    try FileManager.default.createDirectory(at: lyricsDir, withIntermediateDirectories: true)
                }

                // Aria heard the words but couldn't time them to the track (her
                // timestamps landed outside its real length — see
                // `lyrics_ai.timings_are_plausible` on the bridge). Written as
                // PLAIN lyrics, deliberately not to `syncedLyricsURL`.
                //
                // That distinction is the whole point. `loadLyrics()` reads
                // `syncedLyricsURL` FIRST, as the user's own deliberate timing
                // work, ahead of any database — so storing untrustworthy timings
                // there made them permanently authoritative for the track and
                // locked out a genuinely-synced version from LRCLIB. Bad timing
                // is worse than none: untimed words display honestly as a static
                // block (see `LyricsView.isSynced`), whereas wrong ones scroll
                // confidently out of step with the music.
                if !result.synced || result.lrc.isEmpty {
                    try result.plain.write(to: importedPlainLyricsURL(for: song), atomically: true, encoding: .utf8)
                    loadLyrics()
                    ToastCenter.shared.show(
                        "Aria transcribed the words, but couldn't time them to this track",
                        category: .warning, icon: "sparkles"
                    )
                    return
                }

                try result.lrc.write(to: syncedLyricsURL(for: song), atomically: true, encoding: .utf8)
                try? FileManager.default.removeItem(at: importedPlainLyricsURL(for: song))
                loadLyrics()
                ToastCenter.shared.show("Aria generated synced lyrics for this track", category: .success, icon: "sparkles")
            } catch {
                guard player.currentSong?.id == songID else { return }
                lyricsImportError = "Aria couldn't transcribe this track: \(error.localizedDescription)"
            }
        }
    }
}
