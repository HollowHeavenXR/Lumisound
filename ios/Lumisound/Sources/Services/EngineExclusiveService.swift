import Foundation
import SwiftUI
import UIKit

/// Engine-exclusive tracks. Once a track has played on the Lumisound Audio
/// Engine, it's re-encoded with the engine-exclusive flag in its `.lms`
/// header (LMSLOCK2, rust/media/src/lock.rs) so it only ever plays on that
/// engine — the app refuses the system engine for it.
///
/// Never mid-listen: the first time such a track plays, the listener is told
/// it will be re-encoded once they switch off it. When they do, the track
/// is converted in the background (a header rewrite, verified by an unlock +
/// decode round trip, vault tag kept); while that runs it shows a lock
/// overlay wherever it appears and can't be played.
@MainActor
final class EngineExclusiveService: ObservableObject {
    static let shared = EngineExclusiveService()

    /// Songs being re-encoded right now (lock overlay, not playable).
    @Published private(set) var converting: Set<String> = []
    /// Known-exclusive songs (cached `lms_info` reads).
    @Published private(set) var exclusiveIDs: Set<String> = []

    /// Played on the engine, waiting for the listener to switch off them.
    private var pending: [String: URL] = [:]
    private var notified: Set<String> = []
    private var infoChecked: Set<String> = []

    private init() {}

    func isConverting(_ songID: String) -> Bool { converting.contains(songID) }

    /// Whether `song` carries the engine-exclusive flag (reads its header once).
    func isExclusive(_ song: Song) -> Bool {
        if exclusiveIDs.contains(song.id) { return true }
        guard !infoChecked.contains(song.id), let url = song.url, url.isFileURL,
              LumisoundExclusiveExtensionService.isConverted(url) else { return false }
        infoChecked.insert(song.id)
        if lmsInfo(path: url.path).engineExclusive {
            exclusiveIDs.insert(song.id)
            return true
        }
        return false
    }

    /// A track just started on the Lumisound engine.
    func trackStartedOnEngine(_ song: Song) {
        guard let url = song.url, url.isFileURL, LumisoundExclusiveExtensionService.isConverted(url),
              !isExclusive(song), pending[song.id] == nil else { return }
        let info = lmsInfo(path: url.path)
        guard info.locked else { return } // legacy plain bytes: the relock pass handles those first
        pending[song.id] = url
        guard notified.insert(song.id).inserted else { return }
        let body = "When you switch off \"\(song.displayName)\", it will be re-encoded to play on the Lumisound Audio Engine exclusively. It'll be unavailable for a moment while that happens."
        NotificationService.shared.notify(title: "Lumisound Audio Engine", body: body,
                                          identifier: "engine-exclusive-\(song.id)", topic: "system_alerts")
        if UIApplication.shared.applicationState == .active {
            ToastCenter.shared.show("Re-encodes for the Lumisound engine after this track", category: .info, icon: "waveform.badge.checkmark")
        }
    }

    /// The current track changed: convert every pending track the listener
    /// has switched off.
    func currentSongChanged(to song: Song?) {
        let due = pending.filter { $0.key != song?.id }
        for (id, url) in due {
            pending[id] = nil
            Task { await convert(songID: id, url: url) }
        }
    }

    private func convert(songID: String, url: URL) async {
        guard converting.insert(songID).inserted else { return }
        let started = Date()
        let tmp = FileManager.default.temporaryDirectory.path
        let ok = await Task.detached(priority: .utility) {
            lmsSetFlags(path: url.path, engineExclusive: true, lyricsSynced: nil, tmpDir: tmp,
                        verifier: AVFoundationAudioVerifier.shared)
        }.value
        // The playable cache refreshes itself: the re-encoded file is newer.
        converting.remove(songID)
        if ok { exclusiveIDs.insert(songID) }
        infoChecked.insert(songID)
        let secs = Date().timeIntervalSince(started)
        appLog("EngineExclusive: \(url.lastPathComponent) \(ok ? "re-encoded" : "re-encode FAILED") in \(String(format: "%.2f", secs))s", category: "audio")
        RemoteLogger.log(category: "audio_engine", event: ok ? "engine_exclusive_converted" : "engine_exclusive_failed",
                         level: ok ? "info" : "warning", message: url.lastPathComponent,
                         detail: ["seconds": secs, "format": LumisoundExclusiveExtensionService.effectiveExtension(for: url)])
    }
}

/// Lock overlay for a song that's being re-encoded: dimmed, padlock, not tappable.
struct EngineConvertingOverlay: ViewModifier {
    let songID: String
    @ObservedObject private var service = EngineExclusiveService.shared

    func body(content: Content) -> some View {
        let busy = service.isConverting(songID)
        content
            .opacity(busy ? 0.45 : 1)
            .overlay {
                if busy {
                    VStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Re-encoding")
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
