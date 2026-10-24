import MediaPlayer
import SwiftUI

extension SettingsView {

    // MARK: — Playback & Audio Section

    var playbackAudioSection: some View {
        Section {
            // Crossfade (manual, fixed-duration). Mutually exclusive with Smart
            // Auto Crossfade — enabling one turns the other off; either one
            // drives an actual crossfade transition.
            Toggle(isOn: $player.audioSettings.crossfadeEnabled) {
                Label("Crossfade", systemImage: "waveform.path.ecg")
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .tint(.teal)
            .onChange(of: player.audioSettings.crossfadeEnabled) { on in
                if on { player.audioSettings.smartCrossfadeEnabled = false }
            }

            if player.audioSettings.crossfadeEnabled {
                Text("Songs will fade into each other over \(Int(player.audioSettings.crossfadeDuration))s. A smooth, uninterrupted listening experience.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.leading, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Smart Auto Crossfade — independent top-level option (previously
            // nested under Crossfade, so it only worked when manual crossfade was
            // also on). Mutually exclusive with manual Crossfade.
            Toggle(isOn: $player.audioSettings.smartCrossfadeEnabled) {
                Label("Smart Auto Crossfade", systemImage: "metronome")
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .tint(.teal)
            .onChange(of: player.audioSettings.smartCrossfadeEnabled) { on in
                if on {
                    player.audioSettings.crossfadeEnabled = false
                    AudioVisualizerService.shared.start(for: .smartCrossfade)
                } else {
                    AudioVisualizerService.shared.stop(for: .smartCrossfade)
                }
            }

            if player.audioSettings.smartCrossfadeEnabled {
                Text("Analyzes each track's BPM and beatmatches the outgoing and incoming songs, aligning the fade to the beat for a seamless DJ-style transition. Also reads how the outgoing track actually sounds right before it ends — a quiet fade-out gets a longer, gentler blend; a track still at full energy gets a tighter one. Falls back to a normal crossfade when tempo is unknown.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.leading, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Crossfade duration — a manual, fixed setting, which doesn't fit
            // Smart Auto Crossfade's whole premise (it picks its own timing
            // per-transition from tempo + live audio analysis — see
            // `smartFadeDuration`). Shown only for plain manual Crossfade.
            if player.audioSettings.crossfadeEnabled {
                HStack {
                    Label("Duration", systemImage: "timer")
                        .foregroundStyle(AppTheme.textSecondary)
                        .font(AppTheme.bodyFont(size: 14))
                    Spacer()
                    Stepper(
                        value: $player.audioSettings.crossfadeDuration,
                        in: 1...10,
                        step: 1
                    ) {
                        Text("\(Int(player.audioSettings.crossfadeDuration))s")
                            .font(AppTheme.monoFont(size: 14))
                            .foregroundStyle(AppTheme.textPrimary)
                    }
                }
                .padding(.leading, 16)
            }

            if player.audioSettings.crossfadeActive {
                FadeCurvePickerRow(player: player)
            }

            // Gapless playback
            Toggle(isOn: $player.audioSettings.gaplessEnabled) {
                Label("Gapless Playback", systemImage: "infinity")
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .tint(.teal)

            if player.audioSettings.gaplessEnabled {
                Text("Tracks play back-to-back with no silence between them. Ideal for live albums and DJ mixes.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.leading, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // ReplayGain
            Toggle(isOn: $player.audioSettings.replayGainEnabled) {
                Label("ReplayGain", systemImage: "speaker.wave.3")
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .tint(.teal)

            if player.audioSettings.replayGainEnabled {
                Text("Normalises loudness across tracks so volume stays consistent. Reads REPLAYGAIN_TRACK_GAIN metadata when available.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.leading, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Default speed
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Speed", systemImage: "hare")
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    Text(String(format: "%.2f×", player.audioSettings.speed))
                        .font(AppTheme.monoFont(size: 14))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Slider(value: $player.audioSettings.speed, in: 0.5...2.0, step: 0.05)
                    .tint(.teal)
                HStack {
                    Text("0.5×").font(AppTheme.monoFont(size: 11)).foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                    Text("2.0×").font(AppTheme.monoFont(size: 11)).foregroundStyle(AppTheme.textSecondary)
                }
            }

            // Default pitch
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Pitch", systemImage: "music.quarternote.3")
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    Text(pitchLabel(player.audioSettings.pitchSemitones))
                        .font(AppTheme.monoFont(size: 14))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Slider(value: $player.audioSettings.pitchSemitones, in: -12...12, step: 0.5)
                    .tint(.teal)
                HStack {
                    Text("−12 st").font(AppTheme.monoFont(size: 11)).foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                    Text("+12 st").font(AppTheme.monoFont(size: 11)).foregroundStyle(AppTheme.textSecondary)
                }
            }

            // Equalizer toggle
            Toggle(isOn: $player.audioSettings.equalizerEnabled) {
                Label("Equalizer", systemImage: "slider.vertical.3")
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .tint(.teal)

            // EQ Preset picker
            if player.audioSettings.equalizerEnabled {
                // Auto EQ toggle — when on, the preset switches automatically per-track
                // based on tempo (see EQPreset.auto(forBPM:)), so the manual picker
                // below is hidden to avoid implying a fixed preset is in effect.
                Toggle(isOn: $player.audioSettings.autoEQEnabled) {
                    Label("Auto EQ (by genre & tempo)", systemImage: "wand.and.stars")
                        .foregroundStyle(AppTheme.textPrimary)
                }
                .tint(.teal)
                .onChange(of: player.audioSettings.autoEQEnabled) { on in
                    if !on { AudioVisualizerService.shared.stop(for: .autoEQ) }
                }

                if player.audioSettings.autoEQEnabled {
                    Text("Automatically picks the best EQ preset for each track from its genre tag (falling back to its analyzed BPM when untagged), then fine-tunes the bass/treble balance a couple seconds into each track based on a live analysis of how it actually sounds.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.leading, 16)
                        .transition(.opacity.combined(with: .move(edge: .top)))

                    // "Why this pick" — the specific reason for the CURRENT
                    // track, not just the general description above. Same
                    // signal `applyAutoEQIfNeeded` already logs, surfaced
                    // instead of thrown away.
                    if let reason = player.autoEQReason {
                        Label(reason, systemImage: "sparkle.magnifyingglass")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.dynamicAccent)
                            .padding(.leading, 16)
                            .transition(.opacity)
                    }
                }

                if !player.audioSettings.autoEQEnabled {
                    EQPresetPickerRow(player: player)
                }
            }

            // Bass Boost toggle
            Toggle(isOn: $player.audioSettings.bassBoostEnabled) {
                Label("Bass Boost", systemImage: "waveform.path")
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .tint(.teal)

            if player.audioSettings.bassBoostEnabled {
                Text("Boosts the 32 Hz and 64 Hz bands for deeper, punchier bass. Adjust the gain below to taste.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.leading, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Bass Boost gain slider — only shown when enabled
            if player.audioSettings.bassBoostEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Boost Gain", systemImage: "speaker.plus")
                            .foregroundStyle(AppTheme.textSecondary)
                            .font(AppTheme.bodyFont(size: 14))
                        Spacer()
                        Text(String(format: "%.1f dB", player.audioSettings.bassBoostGain))
                            .font(AppTheme.monoFont(size: 14))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    Slider(value: $player.audioSettings.bassBoostGain, in: 0...15, step: 0.5)
                        .tint(.teal)
                    HStack {
                        Text("0 dB").font(AppTheme.monoFont(size: 11)).foregroundStyle(AppTheme.textSecondary)
                        Spacer()
                        Text("15 dB").font(AppTheme.monoFont(size: 11)).foregroundStyle(AppTheme.textSecondary)
                    }
                }
                .padding(.leading, 16)
            }

            // 8D Audio toggle — independent of the Now Playing effects picker
            // now (see AudioSettings.eightDAudioEnabled's doc comment), same
            // "its own toggle, not an exclusive-picker entry" shape as Bass
            // Boost above, so both (plus one picked effect) can run together.
            Toggle(isOn: Binding(
                get: { player.audioSettings.eightDAudioEnabled ?? false },
                set: { player.audioSettings.eightDAudioEnabled = $0 }
            )) {
                Label("8D Audio", systemImage: "rotate.3d")
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .tint(.teal)

            if player.audioSettings.eightDAudioEnabled ?? false {
                Text("Rotates the stereo image left and right to simulate a sound source circling you. Works on any stereo output.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.leading, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                EightDSpeedControl(player: player)
                    .padding(.leading, 16)
            }

            // Reverb toggle — on by default, applies live to whatever is playing.
            Toggle(isOn: $player.audioSettings.reverbEnabled) {
                Label("Reverb", systemImage: "circle.hexagonpath")
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .tint(.teal)

            if player.audioSettings.reverbEnabled {
                Text("Adds a real sense of space to playback. Changes apply instantly to the current track.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.leading, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))

                ReverbPresetPickerRow(player: player)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Mix", systemImage: "dial.medium")
                            .foregroundStyle(AppTheme.textSecondary)
                            .font(AppTheme.bodyFont(size: 14))
                        Spacer()
                        Text("\(Int(player.audioSettings.reverbWetDryMix))%")
                            .font(AppTheme.monoFont(size: 14))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    Slider(value: $player.audioSettings.reverbWetDryMix, in: 0...100, step: 1)
                        .tint(.teal)
                    HStack {
                        Text("Dry").font(AppTheme.monoFont(size: 11)).foregroundStyle(AppTheme.textSecondary)
                        Spacer()
                        Text("Wet").font(AppTheme.monoFont(size: 11)).foregroundStyle(AppTheme.textSecondary)
                    }
                }
                .padding(.leading, 16)
            }

            NavigationLink {
                LuaVisualizerScriptsView()
            } label: {
                Label("Scripted Visualizer (Lua)", systemImage: "waveform.path.ecg.rectangle")
                    .foregroundStyle(AppTheme.textPrimary)
            }

            // Night Mode — gentle dynamic range compression, distinct from the
            // always-on peak limiter. Off by default; opt-in for late-night
            // low-volume listening.
            Toggle(isOn: Binding(
                get: { player.audioSettings.nightModeEnabled ?? false },
                set: { player.audioSettings.nightModeEnabled = $0 }
            )) {
                Label("Night Mode", systemImage: "moon.stars")
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .tint(.teal)

            if player.audioSettings.nightModeEnabled ?? false {
                Text("Evens out quiet and loud passages so quiet parts stay audible and loud parts don't jump out — useful for listening at low volume.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.leading, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Toggle(isOn: Binding(
                get: { player.audioSettings.musicHapticsEnabled ?? false },
                set: { player.audioSettings.musicHapticsEnabled = $0 }
            )) {
                Label("Music Haptics", systemImage: "waveform.and.mic")
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .tint(.teal)
            .disabled(!MusicHapticsService.shared.isAvailable)

            if player.audioSettings.musicHapticsEnabled ?? false {
                Text(
                    MusicHapticsService.shared.isAvailable
                        ? "Adds gentle, audio-reactive vibrations on compatible iPhone hardware. Works with the audio engine path; compatibility-mode streams cannot be synchronized."
                        : "Music Haptics needs a device with Core Haptics support."
                )
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.leading, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Skip Silent Intros — skips near-silent lead-in audio at the start
            // of a local track. Off by default. Was previously two separate,
            // independently-toggled implementations that both partially did
            // this (a weak, hard-coded-threshold 2-second scan gated on
            // `audioSettings.silenceTrimmingEnabled` and run synchronously in
            // `scheduleCurrent`, versus this one — `SilenceTrimService` +
            // `SilenceTrimAnalyzer`, which analyzes up to 10s with a
            // peak-relative threshold and caches the result on-device) —
            // confusing to find two nearly-identical rows in Settings, and
            // the weaker one rarely actually trimmed anything for intros
            // longer than 2s. Consolidated onto the more robust one; see
            // `AudioPlayerManager+Scheduling.swift`'s removed call site.
            Toggle(isOn: $silenceTrim.isEnabled) {
                Label("Skip Silent Intros", systemImage: "forward.end")
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .tint(.teal)

            if silenceTrim.isEnabled {
                Text("Automatically skips past dead air at the very start of a local track (up to 10 seconds), analyzed on-device the first time each track plays. Doesn't apply to streamed tracks.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.leading, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Spatial Audio toggle — HRTF-binaural rendering of the final mix,
            // head-tracked on compatible headphones. Off by default.
            // `spatialAudioEnabled` is `Bool?` (see PlaybackModels.swift for
            // why), so Toggle needs a computed Binding<Bool> wrapper.
            // Mutually exclusive with Mono Audio — enabling one turns the
            // other off, mirroring the Crossfade/Smart Crossfade pattern.
            Toggle(isOn: Binding(
                get: { player.audioSettings.spatialAudioEnabled ?? false },
                set: {
                    player.audioSettings.spatialAudioEnabled = $0
                    if $0 { player.audioSettings.monoAudioEnabled = false }
                }
            )) {
                Label("Spatial Audio", systemImage: "airpods.pro")
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .tint(.teal)

            if player.audioSettings.spatialAudioEnabled ?? false {
                Text(
                    SpatialAudioService.shared.isHeadTrackingAvailable
                        ? "Externalizes the mix and anchors it in space as you turn your head. Works best with AirPods Pro/Max."
                        : "Externalizes the mix in space. Head tracking needs compatible AirPods — without them the sound stays anchored but doesn't follow head movement."
                )
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.leading, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Mono Audio — downmixes to mono, for single-earbud listening or
            // one-sided hearing loss. Mutually exclusive with Spatial Audio.
            Toggle(isOn: Binding(
                get: { player.audioSettings.monoAudioEnabled ?? false },
                set: {
                    player.audioSettings.monoAudioEnabled = $0
                    if $0 { player.audioSettings.spatialAudioEnabled = false }
                }
            )) {
                Label("Mono Audio", systemImage: "ear")
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .tint(.teal)

            if player.audioSettings.monoAudioEnabled ?? false {
                Text("Combines left and right channels into one — the same audio plays from both sides. Useful for single-earbud listening.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.leading, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Toggle(isOn: $bluetoothBattery.isEnabled) {
                Label("Low Battery Alerts", systemImage: "battery.25")
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .tint(.teal)

            if bluetoothBattery.isEnabled {
                Text("Alerts you when a connected Bluetooth accessory's battery drops to 5%. Only works for devices that report battery over the standard Bluetooth LE Battery Service — not AirPods/Beats, which use Apple's own private protocol with no third-party access. Turning this on will prompt for Bluetooth permission.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.leading, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Player error message (if any)
            if let error = player.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(AppTheme.bodyFont(size: 13))
                    .foregroundStyle(AppTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

        } header: {
            sectionHeader("Playback & Audio", icon: "waveform", tint: .teal)
        }
        .listRowBackground(tintedRowBackground(.teal))
        .animation(.easeInOut(duration: 0.22), value: player.audioSettings.crossfadeEnabled)
        .animation(.easeInOut(duration: 0.22), value: player.audioSettings.gaplessEnabled)
        .animation(.easeInOut(duration: 0.22), value: player.audioSettings.replayGainEnabled)
        .animation(.easeInOut(duration: 0.22), value: player.audioSettings.bassBoostEnabled)
        .animation(.easeInOut(duration: 0.22), value: player.audioSettings.reverbEnabled)
        .animation(.easeInOut(duration: 0.22), value: player.audioSettings.spatialAudioEnabled)
        .animation(.easeInOut(duration: 0.22), value: player.audioSettings.smartCrossfadeEnabled)
        .animation(.easeInOut(duration: 0.22), value: player.audioSettings.nightModeEnabled)
        .animation(.easeInOut(duration: 0.22), value: player.audioSettings.musicHapticsEnabled)
        .animation(.easeInOut(duration: 0.22), value: silenceTrim.isEnabled)
        .animation(.easeInOut(duration: 0.22), value: player.audioSettings.monoAudioEnabled)
        .animation(.easeInOut(duration: 0.22), value: bluetoothBattery.isEnabled)
    }
}

/// Isolates one Settings Picker row from `SettingsView`'s own body — which
/// holds ELEVEN other `@EnvironmentObject`/`@ObservedObject` services
/// (`library`, `streaming`, `account`, `cacheManager`, `sleepTimer`, …)
/// besides `player`, every one of which re-ran this whole section (and
/// rebuilt this `Picker`'s native `UIMenu` right along with it) on every
/// publish from ANY of them — exactly the "dropdown menus reset while open"
/// shape already found and fixed for the tracked-playlist and pending-
/// imports "Save to" pickers (see those fixes' commits). `LibraryManager`'s
/// own `isScanning`/background-sync churn alone is independently documented
/// (`LibraryManager+LocalDocumentsScan.swift`) as firing in bursts on
/// foreground-return and routine navigation — exactly when a listener would
/// otherwise have this picker open. Taking only `player` (an `@ObservedObject`,
/// not inherited through the parent's wider environment) means this row now
/// only re-renders on `player`'s own — much less frequent — publishes.
private struct FadeCurvePickerRow: View {
    @ObservedObject var player: AudioPlayerManager

    var body: some View {
        HStack {
            Label("Fade Curve", systemImage: "waveform.path")
                .foregroundStyle(AppTheme.textSecondary)
                .font(AppTheme.bodyFont(size: 14))
            Spacer()
            Picker("", selection: Binding(
                get: { player.audioSettings.crossfadeCurve ?? .equalPower },
                set: { player.audioSettings.crossfadeCurve = $0 }
            )) {
                ForEach(CrossfadeCurve.allCases) { curve in
                    Text(curve.displayName).tag(curve)
                }
            }
            .pickerStyle(.menu)
            .tint(.teal)
        }
        .padding(.leading, 16)
    }
}

/// Same isolation as `FadeCurvePickerRow` above, for the EQ Preset picker.
private struct EQPresetPickerRow: View {
    @ObservedObject var player: AudioPlayerManager

    var body: some View {
        HStack {
            Label("EQ Preset", systemImage: "waveform")
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            Picker("", selection: $player.audioSettings.eqPreset) {
                ForEach(EQPreset.allCases) { preset in
                    Text(preset.displayName)
                        .tag(preset)
                }
            }
            .pickerStyle(.menu)
            .tint(.teal)
            .onChange(of: player.audioSettings.eqPreset) { newPreset in
                player.applyEQPreset(newPreset)
            }
        }
    }
}

/// Same isolation as `FadeCurvePickerRow` above, for the Reverb Room picker.
private struct ReverbPresetPickerRow: View {
    @ObservedObject var player: AudioPlayerManager

    var body: some View {
        HStack {
            Label("Room", systemImage: "square.stack.3d.up")
                .foregroundStyle(AppTheme.textSecondary)
                .font(AppTheme.bodyFont(size: 14))
            Spacer()
            Picker("", selection: $player.audioSettings.reverbPreset) {
                ForEach(ReverbRoomPreset.allCases) { preset in
                    Text(preset.displayName)
                        .tag(preset)
                }
            }
            .pickerStyle(.menu)
            .tint(.teal)
        }
        .padding(.leading, 16)
    }
}

/// Moved here from the Now Playing effects grid (`EffectsView.swift`) along
/// with 8D Audio becoming its own toggle above — this control's binding
/// (`player.rotationHz`/`set8DSpeed`) never actually depended on 8D being
/// the picker's "active effect" in the first place, so it needed no changes
/// beyond relocating.
private struct EightDSpeedControl: View {
    @ObservedObject var player: AudioPlayerManager

    // Preset speeds: label, hz value
    private let presets: [(label: String, hz: Double)] = [
        ("Slow", 0.08), ("Smooth", 0.15), ("Default", 0.18),
        ("Fast", 0.35), ("Wild", 0.70),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "rotate.3d")
                    .font(.caption)
                    .foregroundStyle(AppTheme.dynamicAccent)
                Text("Rotation Speed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text(String(format: "%.2f Hz", player.rotationHz))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.textSecondary)
            }

            // Speed presets
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(presets, id: \.hz) { preset in
                        Button {
                            player.set8DSpeed(hz: preset.hz)
                        } label: {
                            Text(preset.label)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(
                                    abs(player.rotationHz - preset.hz) < 0.01 ? .white : AppTheme.textSecondary
                                )
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    abs(player.rotationHz - preset.hz) < 0.01
                                        ? AnyShapeStyle(AppTheme.dynamicAccent)
                                        : AnyShapeStyle(AppTheme.elevatedSurface),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                        .animation(.easeInOut(duration: 0.15), value: player.rotationHz)
                    }
                }
            }

            // Fine-tune slider
            Slider(
                value: Binding(
                    get: { player.rotationHz },
                    set: { player.set8DSpeed(hz: $0) }
                ),
                in: 0.02...2.0
            )
            .tint(AppTheme.dynamicAccent)
        }
        .padding(.top, 4)
    }
}
