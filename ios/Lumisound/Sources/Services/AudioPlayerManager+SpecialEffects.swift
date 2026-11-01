@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import MediaPlayer
import UIKit

extension AudioPlayerManager {

    // MARK: - 8D Rotation

    func start8DRotation(hz: Double = 0.18) {
        defer { applyRustModulation() }
        stop8DRotation()
        rotationHz = hz
        rotationAngle = 0
        is8DActive = true
        let link = CADisplayLink(target: self, selector: #selector(update8DRotation))
        // update8DRotation advances its phase assuming a 60Hz callback. On
        // ProMotion devices CADisplayLink fires up to 120Hz by default, which
        // would both double the audible rotation speed and double the
        // per-effect CPU/battery cost for no benefit (this drives an audio
        // parameter, not a visual). Pin it to 60 so the math stays correct.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        rotationLink = link
    }

    func stop8DRotation() {
        defer { applyRustModulation() }
        rotationLink?.invalidate()
        rotationLink = nil
        is8DActive = false
        // Reset pan to center so no stereo imbalance remains after 8D effect stops.
        crossfadeMixer.pan = 0.0
    }

    /// Updates the 8D rotation speed while the effect is running. Persists to UserDefaults.
    func set8DSpeed(hz: Double) {
        let clamped = min(max(hz, 0.02), 2.0)
        rotationHz = clamped
        UserDefaults.standard.set(clamped, forKey: "8d_rotation_hz")
        if is8DActive {
            start8DRotation(hz: clamped)
        }
    }

    @objc func update8DRotation() {
        guard is8DActive else { return }
        // Advance angle by one display-link frame. preferredFrameRateRange in
        // start8DRotation pins the link to 60Hz, so this fixed-step math stays
        // correct even on 120Hz ProMotion displays (which would otherwise call
        // back twice as often and double the audible rotation speed).
        rotationAngle += 2 * .pi * rotationHz / 60.0
        // Wrap to keep angle in [0, 2π) to avoid floating-point drift.
        if rotationAngle >= 2 * .pi { rotationAngle -= 2 * .pi }
        // Pan oscillates at the rotation frequency. Scaled to ±0.5 — enough for a clear
        // spatial effect while keeping both channels audible (~-6 dB on the receding side).
        let pan = Float(sin(rotationAngle)) * 0.5
        crossfadeMixer.pan = pan
    }

    // MARK: - Tremolo

    func startTremolo(frequency: Double = 4.0, depth: Float = 0.45) {
        defer { applyRustModulation() }
        stopTremolo()
        tremoloFrequency = frequency
        tremoloDepth = depth
        tremoloPhase = 0
        isTremoloActive = true
        let link = CADisplayLink(target: self, selector: #selector(updateTremolo))
        // Same 60Hz assumption as update8DRotation — pin the rate so the LFO
        // speed stays correct (and the callback doesn't run twice as often)
        // on 120Hz ProMotion displays.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        tremoloLink = link
    }

    func stopTremolo() {
        defer { applyRustModulation() }
        tremoloLink?.invalidate()
        tremoloLink = nil
        isTremoloActive = false
        // Restore both nodes to their normal volume.
        primaryNode.volume = audioSettings.volume
        secondaryNode.volume = audioSettings.volume
    }

    @objc func updateTremolo() {
        guard isTremoloActive, isPlaying else { return }
        tremoloPhase += 2 * .pi * tremoloFrequency / 60.0
        // LFO: volume = baseVolume × (1 − depth/2 + depth/2 × sin(phase))
        // Centres around baseVolume with ±depth/2 swing, never exceeds baseVolume.
        let baseVol = Double(audioSettings.volume)
        let lfo = 1.0 - Double(tremoloDepth) / 2.0 + Double(tremoloDepth) / 2.0 * sin(tremoloPhase)
        let vol = Float(max(0, min(baseVol, baseVol * lfo)))
        if isCrossfading {
            // During crossfade both nodes are audible — apply to the active one only.
            activeNode.volume = vol
        } else {
            primaryNode.volume  = usingPrimaryNode ? vol : audioSettings.volume
            secondaryNode.volume = usingPrimaryNode ? audioSettings.volume : vol
        }
    }

    // MARK: - Vibrato

    func startVibrato(frequency: Double = 4.5, depth: Double = 0.35) {
        stopVibrato()
        vibratoFrequency = frequency
        vibratoDepth = depth
        vibratoPhase = 0
        vibratoBasePitch = audioSettings.pitchSemitones
        isVibratoActive = true
        let link = CADisplayLink(target: self, selector: #selector(updateVibrato))
        // Same 60Hz assumption as update8DRotation — pin the rate so the
        // pitch-modulation speed stays correct (and the callback doesn't run
        // twice as often) on 120Hz ProMotion displays.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        vibratoLink = link
    }

    func stopVibrato() {
        vibratoLink?.invalidate()
        vibratoLink = nil
        isVibratoActive = false
        // Restore pitch to the value captured when vibrato started (or current setting).
        timePitch.pitch = vibratoBasePitch * 100
    }

    @objc func updateVibrato() {
        guard isVibratoActive else { return }
        vibratoPhase += 2 * .pi * vibratoFrequency / 60.0
        let deviation = vibratoDepth * sin(vibratoPhase)
        let totalSemitones = Double(vibratoBasePitch) + deviation
        timePitch.pitch = Float(totalSemitones * 100)  // AVAudioUnitTimePitch.pitch is in cents
    }
}
