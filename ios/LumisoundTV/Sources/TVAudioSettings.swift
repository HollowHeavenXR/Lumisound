import AVFoundation
import Foundation

// MARK: - TVAudioSettings
//
// The playback preferences the settings screen exposes, persisted in
// UserDefaults and read by `TVPlayerModel`.
//
// Aria is deliberately absent. She has no stored flag here and no row on the
// settings screen — there is nothing to read, so there is no disabled path to
// maintain or accidentally leave broken.

@MainActor
final class TVAudioSettings: ObservableObject {
    static let shared = TVAudioSettings()

    private enum Key {
        static let skipSilentIntros = "tv.audio.skipSilentIntros"
        static let spatialize = "tv.audio.allowSpatialization"
        static let crossfade = "tv.player.crossfadeEnabled"
        static let autoCrossfade = "tv.audio.autoCrossfade"
        static let djTransitions = "tv.aria.djTransitions"
        static let gridColumns = "tv.library.gridColumns"
    }

    /// Trims a track's leading silence on start — see `TVSilenceTrim`.
    @Published var skipSilentIntros: Bool {
        didSet { UserDefaults.standard.set(skipSilentIntros, forKey: Key.skipSilentIntros) }
    }

    /// Whether the system may spatialise stereo music.
    ///
    /// This is the setting most likely behind "tvOS doesn't sound as clear as
    /// iOS". An Apple TV with spatial audio on will upmix plain stereo into a
    /// virtualised surround field, which smears the stereo image and is commonly
    /// described exactly that way — less clear, less direct — while the identical
    /// file on a phone plays untouched. It is a real, audible difference that
    /// has nothing to do with the bytes being streamed, and iOS never had it
    /// because headphone/phone playback doesn't take that path.
    ///
    /// Default OFF: music should reach the room as it was mastered, and anyone
    /// who wants the effect can switch it back on.
    @Published var allowSpatialization: Bool {
        didSet {
            UserDefaults.standard.set(allowSpatialization, forKey: Key.spatialize)
            TVRemoteLogger.log(category: "audio", event: "spatialization_changed",
                               detail: ["allowed": allowSpatialization])
        }
    }

    @Published var crossfadeEnabled: Bool {
        didSet { UserDefaults.standard.set(crossfadeEnabled, forKey: Key.crossfade) }
    }

    /// Picks the crossfade length per transition rather than using a fixed six
    /// seconds — see `TVAutoCrossfade`. Only has an effect while `crossfadeEnabled`.
    @Published var autoCrossfade: Bool {
        didSet { UserDefaults.standard.set(autoCrossfade, forKey: Key.autoCrossfade) }
    }

    /// Aria's spoken handover line between tracks. This is a presentation
    /// preference, not an Aria switch — she still picks, still reasons, still
    /// runs. It only controls whether the line is shown.
    @Published var djTransitions: Bool {
        didSet { UserDefaults.standard.set(djTransitions, forKey: Key.djTransitions) }
    }

    /// Cards per row in the library grids. 2 / 3 / 4.
    @Published var gridColumns: Int {
        didSet { UserDefaults.standard.set(gridColumns, forKey: Key.gridColumns) }
    }

    private init() {
        let d = UserDefaults.standard
        // `object(forKey:)` rather than `bool(forKey:)` for the two that default
        // to true — `bool` returns false for an absent key, which would silently
        // ship them off on a fresh install.
        skipSilentIntros = (d.object(forKey: Key.skipSilentIntros) as? Bool) ?? true
        allowSpatialization = (d.object(forKey: Key.spatialize) as? Bool) ?? false
        crossfadeEnabled = d.bool(forKey: Key.crossfade)
        autoCrossfade = (d.object(forKey: Key.autoCrossfade) as? Bool) ?? true
        djTransitions = (d.object(forKey: Key.djTransitions) as? Bool) ?? true
        gridColumns = (d.object(forKey: Key.gridColumns) as? Int) ?? 3
    }
}

// MARK: - TVSilenceTrim
//
// Skip Silent Intros on Apple TV: the same detector as the phone, in the Rust
// core (rust/core/src/intro.rs): silence and steady hiss before the music are
// skipped, quiet musical intros and fade-ins are kept, and playback starts
// 60 ms before the first sound. Files the core can read are analysed in
// place; for streams and anything else, AVFoundation decodes the first 40 s
// and the core analyses those samples.
enum TVSilenceTrim {
    private static let analyzeSeconds: Double = 40
    private static let sampleRate: Double = 11025

    /// Cached per track id for this session (the core also caches per file).
    private static var cache: [String: TimeInterval] = [:]

    static func cachedTrim(for id: String) -> TimeInterval? { cache[id] }

    /// Where playback should start, 0 when there is nothing worth skipping.
    static func analyze(url: URL, trackID: String) async -> TimeInterval {
        if let hit = cache[trackID] { return hit }
        let result = await Task.detached(priority: .utility) { () -> TimeInterval in
            if url.isFileURL, CoreAudio.canDecode(path: url.path) {
                return introSkip(path: url.path, pcm: nil)
            }
            guard let pcm = headPCM(url: url) else { return 0 }
            return introSkip(path: url.absoluteString, pcm: pcm)
        }.value
        cache[trackID] = result
        TVRemoteLogger.log(category: "audio", event: "silence_trim_analyzed",
                           detail: ["trackID": trackID,
                                    "trimSeconds": round(result * 100) / 100,
                                    "applied": result > 0])
        return result
    }

    /// Mono 16-bit PCM at 11.025 kHz of the first 40 s, via AVAssetReader.
    private static func headPCM(url: URL) -> [Int16]? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: analyzeSeconds, preferredTimescale: 600))
        guard reader.startReading() else { return nil }
        var samples: [Int16] = []
        samples.reserveCapacity(Int(sampleRate * analyzeSeconds))
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { p in
                samples.append(contentsOf: UnsafeBufferPointer(start: p, count: length / 2))
            }
        }
        reader.cancelReading()
        return samples.isEmpty ? nil : samples
    }
}
