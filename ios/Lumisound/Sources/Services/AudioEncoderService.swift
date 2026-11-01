import Foundation
import AVFoundation

// MARK: - AudioEncoderService
//
// Converts Opus / WebM / OGG files to a format AVAudioFile can open.
// Four-tier strategy, in order of preference:
//   1. Native: AVAudioFile opens the file directly (iOS 16 handles many Opus files natively)
//   2. Ogg-Opus, hand-decoded: AVFoundation cannot demux a raw Ogg container at all --
//      OggOpusDemuxer + OpusPacketDecoder parse it and decode via AudioConverter's
//      registered Opus codec ourselves, independent of AVAssetReader. Only applies to
//      the `.opus`/`.ogg` extension case (a real Ogg container); WebM-Opus (itag 251,
//      what "Best Quality" often resolves to) has no hand-rolled demuxer yet and falls
//      through to tiers 3/4, which are known not to work for it -- see the doc comment
//      on `oggOpusTranscode` for exactly why this tier is scoped this narrowly.
//   3. Lossless: AVAssetReader decodes to 16-bit PCM → re-encoded as ALAC M4A
//      Identical quality to the Opus decoder's output — no generation loss.
//   4. Fallback: AVAssetExportSession → AAC M4A (for containers AVFoundation can't parse
//      natively, e.g. WebM). Opus is already lossy so the quality loss is negligible.
//
// Results are cached by file mtime + size.

final class AudioEncoderService {
    static let shared = AudioEncoderService()

    private let tempDir: URL

    private init() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumisound_transcode", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        pruneOldCache()
    }

    // MARK: - Playback Transcoding

    func transcodeForPlayback(_ url: URL) async -> URL? {
        // Every tier below needs the file's REAL bytes -- a downloaded track's
        // on-disk `.lms` copy is XOR-masked by LumisoundLockFormat and is not
        // a valid audio container to ANY reader, including these tiers' own,
        // until unlocked. This was missing here entirely (unlike the native
        // AVAudioFile playback path in AudioPlayerManager+Scheduling.swift,
        // which already calls `playableURL` correctly) -- every tier was
        // silently being handed scrambled bytes and failing for that reason
        // alone, independent of whatever container/codec was actually inside.
        // `playableURL` is a no-op passthrough for anything not `.lms`-locked,
        // so this is always safe to call.
        let url = LumisoundExclusiveExtensionService.playableURL(for: url)

        // Tier 1 — native: many formats open directly on iOS 16+
        if (try? AVAudioFile(forReading: url)) != nil { return url }

        let key    = cacheKey(for: url)
        let outURL = tempDir.appendingPathComponent("play_\(key).m4a")

        if FileManager.default.fileExists(atPath: outURL.path) {
            // A prior transcode interrupted mid-write (app killed/backgrounded) can leave a
            // truncated/corrupt .m4a behind. Without validation it would be returned as
            // "cached" forever — pruneOldCache only sweeps files >24h old, and only at the
            // next launch — permanently breaking playback for that track. Probe it first;
            // if it won't open, drop it and fall through to re-transcode.
            if (try? AVAudioFile(forReading: outURL)) != nil {
                return outURL
            }
            try? FileManager.default.removeItem(at: outURL)
        }

        // Tier 2 — hand-decoded Ogg-Opus: AVFoundation can't demux a raw Ogg
        // container at all, so this bypasses AVAssetReader/AVAssetExportSession
        // entirely for this one container type. See `oggOpusTranscode`.
        if await oggOpusTranscode(url, to: outURL, settings: Self.alacSettings) { return outURL }

        // Tier 3 — lossless container: decode to PCM → CD-quality ALAC
        if await losslessTranscode(url, to: outURL) { return outURL }

        // Tier 4 — fallback: AAC re-encode (works for WebM and other exotic containers)
        try? FileManager.default.removeItem(at: outURL)
        return await aacExport(url, to: outURL)
    }

    /// Synchronous counterpart to `transcodeForPlayback`, for a caller (like
    /// `AudioPlayerManager.beginCrossfade`) that cannot await a fresh
    /// transcode at the moment it needs the file without an audible stall.
    /// Returns the same native-or-cached URL `transcodeForPlayback` would,
    /// but only if that work already happened — via a prior prewarm call
    /// against this same source — and never kicks off a transcode itself.
    /// A caller on a deadline should fall back to its own default on `nil`
    /// rather than block here.
    func cachedPlaybackURL(for url: URL) -> URL? {
        let url = LumisoundExclusiveExtensionService.playableURL(for: url)
        if (try? AVAudioFile(forReading: url)) != nil { return url }
        let outURL = tempDir.appendingPathComponent("play_\(cacheKey(for: url)).m4a")
        guard FileManager.default.fileExists(atPath: outURL.path),
              (try? AVAudioFile(forReading: outURL)) != nil else { return nil }
        return outURL
    }

    // MARK: - Permanent Format Conversion (user-triggered, not playback caching)

    /// Permanently re-encodes `url` (typically an opus/webm/ogg file that
    /// only plays via the AVPlayer compatibility fallback) to AAC `.m4a` at
    /// `destinationURL`. Unlike `transcodeForPlayback`, this writes to a
    /// caller-provided permanent location rather than the pruned temp cache,
    /// and always re-encodes rather than checking for a native-open
    /// pass-through — the caller already knows this file needs converting.
    /// Tries the same AAC-export path as `transcodeForPlayback`'s tier 3
    /// first (cheapest — the source is already lossy, so there's no quality
    /// benefit to the heavier decode/re-encode tier). `AVAssetExportSession`
    /// is pickier about input containers than `AVAssetReader` though (this
    /// was previously the ONLY tier permanent conversion tried, so any file
    /// it choked on — a real-world case for some Opus-in-WebM downloads —
    /// silently stayed unconverted forever, retried every 5-minute pass with
    /// the same failure): falls back to the AVAssetReader/AVAssetWriter
    /// decode-then-AAC-encode path `transcodeForPlayback`'s tier 2 already
    /// proves works for these same containers, before giving up. Returns
    /// `true` once `destinationURL` exists and is confirmed playable —
    /// via `CorruptFileFinderService.isValidAudioFile`, the SAME check
    /// every download already goes through, not a separate/weaker
    /// "does AVAudioFile even open it" probe. A conversion is exactly as
    /// consequential as a fresh download (the pre-conversion source gets
    /// deleted right after this returns true — see
    /// `LumisoundExclusiveExtensionService.convert`), so it deserves the
    /// same depth of verification a download already gets, not less.
    func convertPermanently(_ url: URL, to destinationURL: URL) async -> Bool {
        // See the matching comment in `transcodeForPlayback` -- same fix, same
        // reason (a `.lms`-locked source's on-disk bytes are XOR-masked and
        // not a valid audio container until unlocked).
        let url = LumisoundExclusiveExtensionService.playableURL(for: url)

        try? FileManager.default.removeItem(at: destinationURL)
        if await oggOpusTranscode(url, to: destinationURL, settings: Self.aacSettings),
           CorruptFileFinderService.isValidAudioFile(at: destinationURL) {
            return true
        }
        try? FileManager.default.removeItem(at: destinationURL)
        if await aacExport(url, to: destinationURL) != nil,
           CorruptFileFinderService.isValidAudioFile(at: destinationURL) {
            return true
        }
        try? FileManager.default.removeItem(at: destinationURL)
        guard await decodeAndReencode(url, to: destinationURL, settings: Self.aacSettings) else { return false }
        return CorruptFileFinderService.isValidAudioFile(at: destinationURL)
    }

    // MARK: - Ogg-Opus hand-decoded tier

    /// Demuxes a raw Ogg-Opus container (`OggOpusDemuxer`) and decodes its
    /// packets (`OpusPacketDecoder`, via `AudioConverter`'s registered Opus
    /// codec) entirely independent of `AVURLAsset`/`AVAssetReader`/
    /// `AVAssetExportSession` -- none of which can open an Ogg container at
    /// all on iOS, which is the actual root cause of Opus downloads only ever
    /// playing through the reduced AVPlayer "compatibility mode" fallback.
    ///
    /// Deliberately scoped to Ogg containers only: this returns `false`
    /// immediately (falling through to the existing AVAssetReader/
    /// AVAssetExportSession tiers below, unchanged) for anything that isn't a
    /// real Ogg file -- most concretely, WebM-Opus (YouTube's itag 251, what
    /// "Best Quality" often resolves to server-side), which needs a
    /// completely different EBML/Matroska container parser this tier does not
    /// implement. `OggOpusDemuxer.parse` throwing `.notAnOggFile` on the
    /// capture-pattern check is what makes this safe to just always attempt
    /// rather than needing a separate "is this really Ogg" pre-check.
    private func oggOpusTranscode(_ url: URL, to outURL: URL, settings: [String: Any]) async -> Bool {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            appLog("oggOpusTranscode: couldn't read \(url.lastPathComponent) -- \(error)", category: "audio-encoder")
            return false
        }

        let demuxed: OggOpusDemuxer.Result
        do {
            demuxed = try OggOpusDemuxer.parse(data)
        } catch {
            // Expected/benign for anything that isn't a real Ogg container
            // (e.g. WebM-Opus) -- logged at info level, not a warning, since
            // this tier is deliberately only supposed to apply to Ogg files.
            appLog("oggOpusTranscode: not a (supported) Ogg-Opus container for \(url.lastPathComponent) -- \(error)", category: "audio-encoder")
            return false
        }
        guard !demuxed.packets.isEmpty else {
            appWarn("oggOpusTranscode: demuxed 0 packets from \(url.lastPathComponent) (header parsed OK: \(demuxed.header))", category: "audio-encoder")
            return false
        }

        let pcmBuffer: AVAudioPCMBuffer
        do {
            pcmBuffer = try OpusPacketDecoder.decode(
                packets: demuxed.packets,
                opusHeadPacket: demuxed.opusHeadPacketData,
                channelCount: demuxed.header.channelCount,
                preSkip: demuxed.header.preSkip
            )
        } catch {
            appError("oggOpusTranscode: OpusPacketDecoder failed for \(url.lastPathComponent), \(demuxed.packets.count) packets, header \(demuxed.header) -- \(error)", category: "audio-encoder")
            return false
        }
        guard pcmBuffer.frameLength > 0 else {
            appError("oggOpusTranscode: decoded 0 PCM frames from \(demuxed.packets.count) packets for \(url.lastPathComponent)", category: "audio-encoder")
            return false
        }

        try? FileManager.default.removeItem(at: outURL)
        let outFile: AVAudioFile
        do {
            outFile = try AVAudioFile(
                forWriting: outURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            appError("oggOpusTranscode: couldn't open \(outURL.lastPathComponent) for writing -- \(error)", category: "audio-encoder")
            return false
        }

        let outputBuffer = convertedBuffer(
            pcmBuffer,
            sampleRate: (settings[AVSampleRateKey] as? Double) ?? pcmBuffer.format.sampleRate,
            channelCount: AVAudioChannelCount(
                (settings[AVNumberOfChannelsKey] as? Int) ?? Int(pcmBuffer.format.channelCount)
            )
        )
        guard let outputBuffer else {
            appError("oggOpusTranscode: couldn't convert decoded PCM to output format for \(url.lastPathComponent)", category: "audio-encoder")
            try? FileManager.default.removeItem(at: outURL)
            return false
        }

        do {
            try outFile.write(from: outputBuffer)
        } catch {
            appError("oggOpusTranscode: write failed for \(url.lastPathComponent) -- \(error)", category: "audio-encoder")
            try? FileManager.default.removeItem(at: outURL)
            return false
        }

        appLog("oggOpusTranscode: succeeded for \(url.lastPathComponent) -- \(demuxed.packets.count) packets, \(pcmBuffer.frameLength) PCM frames", category: "audio-encoder")
        return true
    }

    /// Resamples/channel-converts decoder output to the exact format requested
    /// by the writer. In particular, the Opus decoder is always 48 kHz while
    /// the CD-quality ALAC profile is 44.1 kHz.
    private func convertedBuffer(
        _ input: AVAudioPCMBuffer,
        sampleRate: Double,
        channelCount: AVAudioChannelCount
    ) -> AVAudioPCMBuffer? {
        guard sampleRate > 0, channelCount > 0 else { return nil }
        guard abs(input.format.sampleRate - sampleRate) > 0.5 ||
              input.format.channelCount != channelCount else {
            return input
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        ),
        let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(
                ceil(Double(input.frameLength) * sampleRate / input.format.sampleRate) + 1
            )
        ),
        let converter = AVAudioConverter(from: input.format, to: outputFormat) else {
            return nil
        }

        var suppliedInput = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if suppliedInput {
                status.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return input
        }
        return conversionError == nil ? output : nil
    }

    // MARK: - Lossless decode via AVAssetReader + AVAssetWriter

    private static let alacSettings: [String: Any] = [
        AVFormatIDKey:            kAudioFormatAppleLossless,
        // CD-quality ALAC is the compatibility baseline. Native files are
        // never resampled; this profile is only used for compatibility-cache
        // transcodes where a deterministic lossless output is required.
        AVSampleRateKey:          44100.0,
        AVNumberOfChannelsKey:    2,
        AVEncoderBitDepthHintKey: 16
    ]

    private static let aacSettings: [String: Any] = [
        AVFormatIDKey:           kAudioFormatMPEG4AAC,
        AVSampleRateKey:         48000.0,
        AVNumberOfChannelsKey:   2,
        AVEncoderBitRateKey:     256_000
    ]

    private func losslessTranscode(_ url: URL, to outURL: URL) async -> Bool {
        await decodeAndReencode(url, to: outURL, settings: Self.alacSettings)
    }

    /// Decodes `url`'s audio to PCM via `AVAssetReader` and re-encodes it
    /// straight to `outURL` with `settings` via `AVAssetWriter` — the
    /// shared engine behind both the lossless (ALAC) playback-cache tier and
    /// the AAC fallback tier of `convertPermanently`. `AVAssetReader` reads
    /// container/codec combinations `AVAssetExportSession` sometimes
    /// refuses, which is the whole reason this exists as a distinct path.
    private func decodeAndReencode(_ url: URL, to outURL: URL, settings: [String: Any]) async -> Bool {
        let asset = AVURLAsset(url: url)

        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              let track = tracks.first else { return false }

        // `.metadata` (not `.commonMetadata`) — the full set of format-
        // specific items, which is where a custom freeform atom like the
        // bridge's `LUMISOUND_ID` tag lives. AVAssetWriter does NOT copy
        // source metadata automatically; without explicitly reading and
        // re-attaching it here, every track that goes through this decode/
        // re-encode path (every WebM/Opus source AVAssetExportSession can't
        // read directly) loses its title/artist/album AND its LUMISOUND_ID
        // — silently defeating cross-device dedupe for exactly those files,
        // despite LumisoundExclusiveExtensionService's header promising
        // that tag "MUST stay plaintext/ffprobe-readable."
        let sourceMetadata = (try? await asset.load(.metadata)) ?? []

        guard let reader = try? AVAssetReader(asset: asset) else { return false }

        // Decode to PCM at the writer's requested rate. The ALAC cache uses
        // the 44.1 kHz CD-quality baseline, while the AAC fallback keeps its
        // existing 48 kHz profile.
        let outputSampleRate = (settings[AVSampleRateKey] as? Double) ?? 44100.0
        let outputChannelCount = (settings[AVNumberOfChannelsKey] as? Int) ?? 2
        let pcmSettings: [String: Any] = [
            AVFormatIDKey:               kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey:      16,
            AVLinearPCMIsFloatKey:       false,
            AVLinearPCMIsBigEndianKey:   false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey:             outputSampleRate,
            AVNumberOfChannelsKey:       outputChannelCount
        ]
        let readerOut = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings)
        guard reader.canAdd(readerOut) else { return false }
        reader.add(readerOut)

        guard let writer = try? AVAssetWriter(outputURL: outURL, fileType: .m4a) else { return false }
        writer.metadata = sourceMetadata
        let writerIn = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        writerIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerIn) else { return false }
        writer.add(writerIn)

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        return await withCheckedContinuation { cont in
            writerIn.requestMediaDataWhenReady(on: .global(qos: .utility)) {
                while writerIn.isReadyForMoreMediaData {
                    if reader.status == .failed || writer.status == .failed {
                        writerIn.markAsFinished()
                        writer.cancelWriting()
                        try? FileManager.default.removeItem(at: outURL)
                        cont.resume(returning: false)
                        return
                    }
                    if let buf = readerOut.copyNextSampleBuffer() {
                        writerIn.append(buf)
                    } else {
                        writerIn.markAsFinished()
                        writer.finishWriting {
                            if writer.status != .completed {
                                try? FileManager.default.removeItem(at: outURL)
                            }
                            cont.resume(returning: writer.status == .completed)
                        }
                        return
                    }
                }
            }
        }
    }

    // MARK: - Fallback AAC export

    private func aacExport(_ url: URL, to outURL: URL) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset,
                                                  presetName: AVAssetExportPresetAppleM4A) else {
            return nil
        }
        session.outputFileType = .m4a
        session.outputURL      = outURL
        // AVAssetExportSession does NOT carry source metadata over to the
        // output file unless explicitly told to — leaving `.metadata` unset
        // (the previous behavior here) silently strips title/artist/album
        // and, critically, the bridge's plaintext LUMISOUND_ID tag that
        // cross-device dedupe depends on. See the matching comment in
        // `decodeAndReencode`.
        session.metadata = (try? await asset.load(.metadata)) ?? []

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }

        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: outURL)
            return nil
        }
        return outURL
    }

    // MARK: - Helpers

    private func cacheKey(for url: URL) -> String {
        let path  = url.standardizedFileURL.path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size  = (attrs?[.size] as? Int) ?? 0
        return "\(abs(path.hashValue))_\(Int(mtime))_\(size)"
    }

    private func pruneOldCache() {
        let fm     = FileManager.default
        let cutoff = Date().addingTimeInterval(-86400)
        guard let files = try? fm.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix("play_") {
            if let d = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate, d < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }
}
