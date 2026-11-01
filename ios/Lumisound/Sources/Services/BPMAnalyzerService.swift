import Foundation
import AVFoundation
import CoreMedia

// MARK: - BPMAnalyzerService
//
// On-device tempo estimation for any track the player can open — local
// imports, watched-folder files, and Apple Music items alike. This is a
// Swift port of the bridge's `_estimate_bpm` (ios-bridge/main.py): decode the
// first 60s to mono 11025Hz PCM, build a coarse energy-onset envelope
// (~50 frames/sec), and autocorrelate it to find the dominant beat period in
// the 60-200 BPM range. Results are cached on disk by file path + mtime +
// size so repeat lookups (e.g. re-arming the "Up Next" track on every
// crossfade) are free.

actor BPMAnalyzerService {
    static let shared = BPMAnalyzerService()

    private init() {
        // One-time import of the Swift-era cache (same key format) into the core store.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        if let data = try? Data(contentsOf: caches.appendingPathComponent("bpm_cache_v1.json")) {
            bpmImportLegacy(json: data)
        }
    }

    /// Tempo of the first 60 s, cached by path + mtime + size (Rust core:
    /// symphonia decode + energy-onset autocorrelation, as on the bridge).
    func bpm(for url: URL) async -> Double? {
        let path = url.standardizedFileURL.path
        if let v = bpmCached(path: path) { return v }
        // Formats the core decoder can't read (Opus/WebM) are decoded here.
        var pcm: [Int16]? = nil
        if !CoreAudio.canDecode(path: path) {
            pcm = await Self.decodeMonoAV(url: url, sampleRate: 11025, maxSeconds: 60)
            if pcm == nil { return nil }
        }
        return CoreAudio.bpm(path: path, pcm: pcm)
    }

    /// Mono 16-bit PCM at `sampleRate` for the first `maxSeconds` — decoded by
    /// the Rust core; AVAssetReader only for formats it can't read.
    static func decodeMono(url: URL, sampleRate: Double, maxSeconds: Double) async -> [Int16]? {
        if let s = CoreAudio.mono(path: url.path, sampleRate: sampleRate, start: 0, maxSeconds: maxSeconds) {
            return s
        }
        return await decodeMonoAV(url: url, sampleRate: sampleRate, maxSeconds: maxSeconds)
    }

    /// Decodes the first `maxSeconds` of `url`'s audio track to mono 16-bit PCM
    /// at `sampleRate`. Returns `nil` if the file has no audio track or can't
    /// be opened by `AVAssetReader`. Internal (not `private`) since
    /// `PitchContourService` (hum-to-search) reuses this exact decode path
    /// rather than duplicating its own `AVAssetReader` boilerplate.
    static func decodeMonoAV(url: URL, sampleRate: Double, maxSeconds: Double) async -> [Int16]? {
        // Shared decode path reused by tempo detection, Hum-to-Search
        // (PitchContourService), and Skip Silent Intros (SilenceTrimAnalyzer)
        // -- a `.lms`-locked url's on-disk bytes are XOR-masked and
        // unreadable by AVURLAsset until unlocked, which silently defeated
        // all three features for every locked track.
        let asset = AVURLAsset(url: LumisoundExclusiveExtensionService.playableURL(for: url))
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              let track = tracks.first,
              let reader = try? AVAssetReader(asset: asset)
        else { return nil }

        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 {
                reader.timeRange = CMTimeRange(
                    start: .zero,
                    duration: CMTime(seconds: min(seconds, maxSeconds), preferredTimescale: 600)
                )
            }
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }

        let maxSamples = Int(sampleRate * maxSeconds)
        var samples: [Int16] = []
        samples.reserveCapacity(maxSamples)

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                let length = CMBlockBufferGetDataLength(blockBuffer)
                var chunk = [Int16](repeating: 0, count: length / MemoryLayout<Int16>.size)
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &chunk)
                samples.append(contentsOf: chunk)
            }
            if samples.count >= maxSamples {
                break
            }
        }

        if samples.count > maxSamples {
            samples.removeSubrange(maxSamples...)
        }
        return samples.isEmpty ? nil : samples
    }
}
