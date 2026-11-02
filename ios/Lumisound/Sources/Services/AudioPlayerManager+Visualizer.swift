@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import MediaPlayer
import UIKit

extension AudioPlayerManager {

    // MARK: - Visualizer Tap
    //
    // Installed on `mainMixerNode` for analysis only — a read-only monitoring
    // tap, not an insert node, so it never affects what's actually played.

    func startVisualizerTap(handler: @escaping (AVAudioPCMBuffer) -> Void) {
        guard !visualizerTapInstalled else { return }
        visualizerTapInstalled = true
        // The spectrum uses a 2048-point FFT, but processing every 2048-frame
        // callback creates a main-actor update roughly 40 times per second.
        // A 4096-frame tap preserves the FFT resolution while halving callback,
        // allocation, and SwiftUI publication overhead.
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            // Heat-governed rate: most buffers are dropped here, before any work.
            guard AudioVisualizerService.wantsSample() else { return }
            handler(buffer)
        }
        // Rust engine: poll its output tap ~23x/s (4096 frames at 48 kHz per
        // AVAudioEngine tap callback is ~11.7/s; this keeps bars smooth).
        let rate = Double(Self.rust.outputRate())
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48_000, channels: 1) else { return }
        rustTapTimer?.invalidate()
        rustTapTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 23.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isUsingRustEngine, self.isPlaying,
                      AudioVisualizerService.wantsSample() else { return }
                let samples = Self.rust.tapSamples(count: 4096)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                      let ch = buffer.floatChannelData?[0] else { return }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { src in ch.update(from: src.baseAddress!, count: samples.count) }
                handler(buffer)
            }
        }
    }

    func stopVisualizerTap() {
        guard visualizerTapInstalled else { return }
        visualizerTapInstalled = false
        engine.mainMixerNode.removeTap(onBus: 0)
        rustTapTimer?.invalidate()
        rustTapTimer = nil
    }
}
