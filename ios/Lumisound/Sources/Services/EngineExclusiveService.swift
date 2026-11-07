import Foundation
import SwiftUI
import UIKit

/// Engine-exclusive tracks. A track re-encoded with the engine-exclusive flag
/// in its `.lms` header (LMSLOCK2, rust/media/src/lock.rs) only ever plays on
/// the Lumisound Audio Engine; the app refuses the system engine for it.
///
/// Two ways a track gets there:
/// * Background conversion (`startBackgroundConversion`): the whole library,
///   a few tracks a second, without waiting for anything to be played. Each
///   track is first checked to decode on the Lumisound engine (an exclusive
///   track the engine couldn't play would be unplayable), and the pass
///   waits for thermal headroom (HeatGovernor) so it never heats the phone.
/// * The playing track is never touched mid-listen: it's converted as soon
///   as the listener switches off it.
///
/// While a track is being re-encoded it can't be played; if that takes more
/// than a moment, a lock overlay shows wherever the track appears. Converted
/// tracks carry a lock badge (`SongFormatBadge`) everywhere they're listed.
@MainActor
final class EngineExclusiveService: ObservableObject {
    static let shared = EngineExclusiveService()

    /// Known engine-exclusive songs (persisted). Published in batches so a
    /// background pass doesn't re-render every visible row per track.
    @Published private(set) var exclusiveIDs: Set<String> = []
    /// Lock overlays on screen: songs whose re-encode has run long enough
    /// to be worth showing (most take ~50 ms and never flash an overlay).
    @Published private(set) var lockLabels: [String: String] = [:]
    /// Tracks left for the background pass (updated once per batch).
    @Published private(set) var remaining = 0

    /// Songs being re-encoded right now: not playable (not published).
    private var busy: Set<String> = []
    private var pendingExclusive: Set<String> = []
    private var flushScheduled = false
    /// Played on the engine, waiting for the listener to switch off them.
    private var pending: [String: URL] = [:]
    private var infoChecked: Set<String> = []
    /// Tracks the engine can't decode (or whose re-encode failed): never
    /// made exclusive, not retried this session.
    private var skipped: Set<String> = []
    private var backgroundTask: Task<Void, Never>?
    private weak var library: LibraryManager?
    private weak var player: AudioPlayerManager?
    private var announcedBatch = false
    private var convertedThisRun = 0

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("engine_exclusive_ids.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.storeURL),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            exclusiveIDs = Set(ids)
        }
    }

    func isConverting(_ songID: String) -> Bool { busy.contains(songID) }

    /// Whether `song` carries the engine-exclusive flag (reads its header once).
    func isExclusive(_ song: Song) -> Bool {
        if exclusiveIDs.contains(song.id) || pendingExclusive.contains(song.id) { return true }
        guard !infoChecked.contains(song.id), let url = song.url, url.isFileURL,
              LumisoundExclusiveExtensionService.isConverted(url) else { return false }
        infoChecked.insert(song.id)
        if lmsInfo(path: url.path).engineExclusive {
            markExclusive(song.id)
            return true
        }
        return false
    }

    // MARK: Locks

    /// Locks `songID` (not playable; overlay after a moment) for a re-encode
    /// job. False when it's already locked.
    func beginLock(_ songID: String, label: String) -> Bool {
        guard busy.insert(songID).inserted else { return false }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, self.busy.contains(songID) else { return }
            self.lockLabels[songID] = label
        }
        return true
    }

    func endLock(_ songID: String) {
        busy.remove(songID)
        if lockLabels[songID] != nil { lockLabels[songID] = nil }
    }

    private func markExclusive(_ id: String) {
        guard !exclusiveIDs.contains(id), pendingExclusive.insert(id).inserted else { return }
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.flushExclusive()
        }
    }

    private func flushExclusive() {
        flushScheduled = false
        guard !pendingExclusive.isEmpty else { return }
        exclusiveIDs.formUnion(pendingExclusive)
        pendingExclusive.removeAll()
        let ids = Array(exclusiveIDs)
        let url = Self.storeURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(ids) { try? data.write(to: url, options: .atomic) }
        }
    }

    // MARK: Playing track

    /// A track just started on the Lumisound engine: it's converted the
    /// moment the listener switches off it (never mid-listen).
    func trackStartedOnEngine(_ song: Song) {
        guard let url = song.url, url.isFileURL, LumisoundExclusiveExtensionService.isConverted(url),
              !isExclusive(song), pending[song.id] == nil else { return }
        guard lmsInfo(path: url.path).locked else { return } // legacy plain bytes: the relock pass handles those first
        pending[song.id] = url
    }

    /// The current track changed: convert every pending track the listener
    /// has switched off.
    func currentSongChanged(to song: Song?) {
        let due = pending.filter { $0.key != song?.id }
        for (id, url) in due {
            pending[id] = nil
            Task { _ = await convert(songID: id, url: url, checkDecode: false) }
        }
    }

    // MARK: Background pass

    /// Converts the whole library in the background, a batch at a time.
    func startBackgroundConversion(library: LibraryManager, player: AudioPlayerManager) {
        self.library = library
        self.player = player
        guard backgroundTask == nil else { return }
        backgroundTask = Task { [weak self] in
            // Let launch (library load, first playback) settle first.
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            while !Task.isCancelled {
                let done = await self?.runBatch() ?? 0
                // Keep going while there's work; otherwise look again later
                // (imports and the relock pass add new `.lms` tracks).
                try? await Task.sleep(nanoseconds: done > 0 ? 1_500_000_000 : 300_000_000_000)
            }
        }
    }

    private func candidates() -> [(String, URL)] {
        guard let songs = library?.allSongs else { return [] }
        let current = player?.currentSong?.id
        let next = player?.peekNextSong()?.id
        return songs.compactMap { song in
            guard song.id != current, song.id != next,
                  !exclusiveIDs.contains(song.id), !pendingExclusive.contains(song.id),
                  !skipped.contains(song.id), !busy.contains(song.id),
                  let url = song.url, url.isFileURL,
                  LumisoundExclusiveExtensionService.isConverted(url) else { return nil }
            return (song.id, url)
        }
    }

    private func runBatch() async -> Int {
        // The Settings toggle is the listener's choice: with the Lumisound
        // engine off, nothing is made exclusive to it.
        guard AudioPlayerManager.rustEngineEnabled else { return 0 }
        let todo = candidates()
        remaining = todo.count
        guard !todo.isEmpty else {
            if convertedThisRun > 0 {
                NotificationService.shared.notify(
                    title: "Lumisound Audio Engine",
                    body: "Your library is converted: \(convertedThisRun) tracks now play on the Lumisound Audio Engine exclusively.",
                    identifier: "engine-exclusive-done", topic: "system_alerts")
                RemoteLogger.log(category: "audio_engine", event: "engine_exclusive_pass_done", level: "info",
                                 message: "\(convertedThisRun) converted", detail: ["converted": convertedThisRun])
                convertedThisRun = 0
                announcedBatch = false
            }
            return 0
        }
        guard await HeatGovernor.waitForHeadroom(job: "engine_exclusive", maxWait: 120) else { return 0 }
        if !announcedBatch, todo.count >= 25 {
            announcedBatch = true
            NotificationService.shared.notify(
                title: "Lumisound Audio Engine",
                body: "Converting \(todo.count) tracks to play on the Lumisound Audio Engine exclusively. This runs in the background; a track is unavailable only for the moment it's being re-encoded.",
                identifier: "engine-exclusive-start", topic: "system_alerts")
        }
        for (id, url) in todo.prefix(24) {
            if Task.isCancelled { break }
            // The listener may have just started it.
            if player?.currentSong?.id == id { continue }
            await convert(songID: id, url: url, checkDecode: true)
            // Small breather between files: steady, low-priority I/O.
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return 1 // there was work: look again soon
    }

    /// Re-encodes one track as engine-exclusive. `checkDecode`: first make
    /// sure the Lumisound engine can play it.
    @discardableResult
    private func convert(songID: String, url: URL, checkDecode: Bool) async -> Bool {
        guard beginLock(songID, label: "Re-encoding") else { return false }
        defer { endLock(songID) }
        let started = Date()
        let tmp = FileManager.default.temporaryDirectory.path
        let outcome: ExclusiveOutcome = await Task.detached(priority: .utility) {
            let info = lmsInfo(path: url.path)
            if info.engineExclusive { return .already }
            guard info.locked else { return .notLocked }
            if checkDecode, !CoreAudio.canDecode(path: url.path) { return .undecodable }
            return lmsSetFlags(path: url.path, engineExclusive: true, lyricsSynced: nil, tmpDir: tmp,
                               verifier: AVFoundationAudioVerifier.shared) ? .converted : .failed
        }.value
        infoChecked.insert(songID)
        switch outcome {
        case .converted, .already:
            markExclusive(songID)
            if outcome == .converted { convertedThisRun += 1 }
        case .notLocked, .undecodable, .failed:
            // notLocked: the relock pass locks it first; picked up next session.
            skipped.insert(songID)
        }
        guard outcome != .already, outcome != .notLocked else { return false }
        let secs = Date().timeIntervalSince(started)
        let event: String
        switch outcome {
        case .converted: event = "engine_exclusive_converted"
        case .undecodable: event = "engine_exclusive_undecodable"
        default: event = "engine_exclusive_failed"
        }
        if outcome != .converted {
            appLog("EngineExclusive: \(url.lastPathComponent) \(event) in \(String(format: "%.2f", secs))s", category: "audio")
        }
        // Successes are many on a first pass: sample them; report every problem.
        if outcome != .converted || convertedThisRun % 50 == 1 {
            RemoteLogger.log(category: "audio_engine", event: event, level: outcome == .converted ? "info" : "warning",
                             message: url.lastPathComponent,
                             detail: ["seconds": secs, "format": LumisoundExclusiveExtensionService.effectiveExtension(for: url),
                                      "convertedThisRun": convertedThisRun, "remaining": remaining])
        }
        return outcome == .converted
    }
}

private enum ExclusiveOutcome: Sendable { case converted, already, notLocked, undecodable, failed }

/// Lock overlay for a song that's being re-encoded: dimmed, padlock, not tappable.
struct EngineConvertingOverlay: ViewModifier {
    let songID: String
    @ObservedObject private var service = EngineExclusiveService.shared

    func body(content: Content) -> some View {
        let label = service.lockLabels[songID]
        let busy = label != nil
        content
            .opacity(busy ? 0.45 : 1)
            .overlay {
                if let label {
                    VStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(AppTheme.dynamicAccent)
                        Text(label)
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(AppTheme.textPrimary)
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .transition(.opacity)
                }
            }
            .allowsHitTesting(!busy)
            .animation(.easeInOut(duration: 0.2), value: busy)
    }
}

extension View {
    /// Locks and dims this song's row/card while it's being re-encoded.
    func engineConvertingOverlay(songID: String) -> some View {
        modifier(EngineConvertingOverlay(songID: songID))
    }
}

/// Accent padlock marking an engine-exclusive track (plays only on the
/// Lumisound Audio Engine). Shown with the format tags on every row/card.
struct EngineLockBadge: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(AppTheme.dynamicAccent)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(AppTheme.dynamicAccent.opacity(0.5), lineWidth: 1)
            )
            .accessibilityLabel("Plays on the Lumisound Audio Engine only")
    }
}
