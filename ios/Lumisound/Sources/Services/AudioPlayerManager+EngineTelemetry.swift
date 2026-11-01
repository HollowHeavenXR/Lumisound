import AVFoundation
import Foundation
import UIKit

/// Lumisound Audio Engine telemetry → the bridge's event log (category
/// `audio_engine`). The engine measures everything itself (rust/core/src/
/// engine/health.rs: underruns by phase, callback load/overruns, late
/// callbacks, lock misses, NaN/clipping, decode errors/speed, start latency,
/// output errors); this adds the playback context and uploads:
///
/// * `engine_incident` (error) — right away when something severe happens: a
///   track failed or stopped decoding early, the output device errored, or
///   a dropout of 250 ms or more.
/// * `engine_health` (warning) — at most once a minute when anything audible
///   or risky happened (any underrun, overrun, lock miss, decode error…).
/// * `engine_heartbeat` (info) — every 15 min of playback, so problem rates
///   can be computed against clean listening time.
/// * `engine_fallback` (warning) — the AVAudioEngine path had to take over,
///   with the reason.
extension AudioPlayerManager {
    private static var engineTelemetryTimer: Timer?
    private static var lastEngineUpload = Date.distantPast
    private static var lastEngineHeartbeat = Date()
    private static var lastSevereCounters: (UInt64, UInt64, UInt64, Double) = (0, 0, 0, 0)
    private static var fallbackReported: Set<String> = []

    /// Starts the 10 s health poll (idempotent). Called once the engine's output is up.
    func startEngineTelemetry() {
        guard Self.engineTelemetryTimer == nil else { return }
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollEngineHealth() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        Self.engineTelemetryTimer = t
    }

    private func pollEngineHealth() {
        // Cheap counter read; the draining report is only taken when uploading.
        let h = Self.rust.health()
        let severeNow = (h.deckFailures, h.outputErrors, h.decodeStoppedEarly, h.underrunMs)
        let prev = Self.lastSevereCounters
        let underrunJump = h.underrunMs - prev.3
        let severe = h.deckFailures > prev.0 || h.outputErrors > prev.1 || h.decodeStoppedEarly > prev.2 || underrunJump >= 250
        let now = Date()
        if severe || now.timeIntervalSince(Self.lastEngineUpload) >= 60 {
            let report = Self.rust.healthReport()
            Self.lastSevereCounters = severeNow
            if report.hasProblems {
                Self.lastEngineUpload = now
                upload(report: report, event: report.severe ? "engine_incident" : "engine_health",
                       level: report.severe ? "error" : "warning")
            } else if isPlaying, now.timeIntervalSince(Self.lastEngineHeartbeat) >= 15 * 60 {
                Self.lastEngineHeartbeat = now
                upload(report: report, event: "engine_heartbeat", level: "info")
            }
        }
    }

    private func upload(report: EngineReport, event: String, level: String) {
        var detail = (engineReportJson(report: report).data(using: .utf8))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        detail["context"] = engineContext()
        let d = report.delta
        let summary = String(format: "%.0fs played: %llu underrun(s) %.0f ms, %llu overrun(s), load max %.0f%%, %llu decode error(s), %llu output error(s)",
                             d.playingSeconds, d.underrunEvents, d.underrunMs, d.callbackOverruns,
                             report.totals.callbackLoadMax * 100, d.decodeErrors, d.outputErrors)
        RemoteLogger.log(category: "audio_engine", event: event, level: level, message: summary, detail: detail)
        if level != "info" { appWarn("Audio engine \(event): \(summary)", category: "audio") }
    }

    /// What was playing and how, for correlating problems with formats,
    /// effects, routes and device state.
    func engineContext() -> [String: Any] {
        let s = audioSettings
        let session = AVAudioSession.sharedInstance()
        var ctx: [String: Any] = [
            "isPlaying": isPlaying,
            "positionSeconds": Int(position),
            "durationSeconds": Int(duration),
            "speed": s.speed,
            "pitchSemitones": s.pitchSemitones,
            "eq": s.equalizerEnabled,
            "bassBoost": s.bassBoostEnabled,
            "reverb": s.reverbEnabled,
            "reverbPreset": s.reverbPreset.rawValue,
            "nightMode": s.nightModeEnabled == true,
            "mono": s.monoAudioEnabled == true,
            "eightD": is8DActive || s.eightDAudioEnabled == true,
            "tremolo": isTremoloActive,
            "vibrato": isVibratoActive,
            "spatial": rustSpatialTracking,
            "crossfade": s.crossfadeActive,
            "smartCrossfade": s.smartCrossfadeEnabled,
            "gapless": s.gaplessEnabled,
            "crossfading": isCrossfading,
            "sessionSampleRate": session.sampleRate,
            "ioBufferMs": session.ioBufferDuration * 1000,
            "outputLatencyMs": session.outputLatency * 1000,
            "route": session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ","),
            "thermal": ProcessInfo.processInfo.thermalState.rawValue,
            "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "background": UIApplication.shared.applicationState == .background,
        ]
        if let song = currentSong {
            ctx["songID"] = song.id
            if let url = song.url {
                ctx["format"] = LumisoundExclusiveExtensionService.effectiveExtension(for: url)
                ctx["locked"] = LumisoundExclusiveExtensionService.isConverted(url)
                ctx["source"] = url.isFileURL ? (song.sourceTrackID == nil ? "local" : "downloaded") : "stream"
            }
            ctx["bitrateKbps"] = song.bitrate
            ctx["fileSampleRate"] = song.sampleRate
        }
        return ctx
    }

    /// The AVAudioEngine path took over from the Lumisound Audio Engine.
    /// One event per (reason, format) per session.
    func reportEngineFallback(reason: String, url: URL?, error: String? = nil) {
        let ext = url.map { LumisoundExclusiveExtensionService.effectiveExtension(for: $0) } ?? "?"
        guard Self.fallbackReported.insert("\(reason)|\(ext)").inserted else { return }
        var detail = engineContext()
        detail["reason"] = reason
        detail["format"] = ext
        if let error { detail["error"] = error }
        RemoteLogger.log(category: "audio_engine", event: "engine_fallback", level: "warning",
                         message: "\(reason) (\(ext))\(error.map { ": \($0)" } ?? "")", detail: detail)
    }

    /// Current engine health for the periodic diagnostics snapshot.
    static func engineHealthSnapshot() -> [String: Any] {
        let h = rust.health()
        return [
            "playingSeconds": Int(h.playingSeconds),
            "sampleRate": h.sampleRate,
            "bufferFrames": h.bufferFrames,
            "callbackLoadAvg": (h.callbackLoadAvg * 100).rounded() / 100,
            "callbackLoadMax": (h.callbackLoadMax * 100).rounded() / 100,
            "callbackOverruns": h.callbackOverruns,
            "lateCallbacks": h.lateCallbacks,
            "lockMisses": h.lockMisses,
            "underruns": h.underrunEvents,
            "underrunMs": Int(h.underrunMs),
            "nonFiniteSamples": h.nonfiniteSamples,
            "clippedSamples": h.clippedSamples,
            "decodeErrors": h.decodeErrors,
            "deckFailures": h.deckFailures,
            "decodeStoppedEarly": h.decodeStoppedEarly,
            "slowStarts": h.slowStarts,
            "startLatencyMaxMs": Int(h.startLatencyMaxMs),
            "decodeSpeedMin": (h.decodeSpeedMin * 10).rounded() / 10,
            "outputErrors": h.outputErrors,
        ]
    }
}
