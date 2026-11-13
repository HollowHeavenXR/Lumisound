import SwiftUI

// MARK: - TVSettingsView
//
// Playback and display preferences, reached from the Account screen.
//
// Aria Lumi has no row here. That is deliberate and stated on the screen rather
// than left as a silent omission — a missing switch reads as an oversight, and
// someone looking for it should find the answer instead of wondering. The only
// Aria-related control is whether her spoken handover line is DISPLAYED, which
// is a presentation choice and does not turn her off.
struct TVSettingsView: View {
    @ObservedObject private var settings = TVAudioSettings.shared
    @ObservedObject private var aria = TVAria.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVMetrics.section) {
                TVScreenTitle(title: "Settings", eyebrow: "Account")

                section("Playback") {
                    toggleRow(
                        title: "Skip Silent Intros",
                        detail: "Starts a track at its first real sound, skipping a silent or fading-in lead-in.",
                        systemImage: "scissors",
                        isOn: $settings.skipSilentIntros
                    )
                    toggleRow(
                        title: "Crossfade",
                        detail: "Overlaps the end of one track with the start of the next.",
                        systemImage: "arrow.triangle.merge",
                        isOn: $settings.crossfadeEnabled
                    )
                    if settings.crossfadeEnabled {
                        toggleRow(
                            title: "Auto Crossfade",
                            detail: "Sets the overlap per track instead of a fixed six seconds — tighter when a track ends abruptly, longer when it fades out, and snapped to the beat where the tempo is known.",
                            systemImage: "waveform.path.ecg",
                            isOn: $settings.autoCrossfade
                        )
                    }
                }

                section("Sound · Lumisound Engine") {
                    toggleRow(
                        title: "LumiEQ",
                        detail: "The phone's equalizer, running in the Lumisound engine on this Apple TV.",
                        systemImage: "slider.vertical.3",
                        isOn: $settings.eqEnabled
                    )
                    if settings.eqEnabled { eqPresetRow }
                    toggleRow(
                        title: "Night Mode",
                        detail: "Evens out loud and quiet passages so late, low listening stays clear without waking the house.",
                        systemImage: "moon.stars",
                        isOn: $settings.nightMode
                    )
                    roomRow
                }

                section("Aria Lumi") {
                    ariaNotice
                    toggleRow(
                        title: "Show Aria's Track Intros",
                        detail: "Displays her one-line handover as a new track begins. Aria keeps running either way — this only controls whether the line is shown.",
                        systemImage: "text.bubble",
                        isOn: $settings.djTransitions
                    )
                }

                section("Library") {
                    columnsRow
                }
            }
            .padding(.bottom, 80)
        }
        .tvAmbientBackground()
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title.uppercased())
                .font(TVType.eyebrow)
                .tracking(2.4)
                .foregroundStyle(TVPalette.neonAlt)
                .padding(.horizontal, TVMetrics.margin + 8)
            VStack(spacing: 4) {
                content()
            }
            .padding(10)
            .tvGlassPanel(cornerRadius: 30)
            .padding(.horizontal, TVMetrics.margin)
        }
        // Readable line length: settings copy is prose, and a 1700pt-wide row
        // puts the switch a long way from the words it controls.
        .frame(maxWidth: 1300, alignment: .leading)
    }

    /// Says plainly why there is no on/off switch, rather than leaving a gap.
    private var ariaNotice: some View {
        HStack(alignment: .top, spacing: 16) {
            TVAriaMark(isAnimating: true, diameter: 30)
            VStack(alignment: .leading, spacing: 6) {
                Text("Aria is always on")
                    .font(.system(size: 25, weight: .semibold))
                Text("She picks a track for you each day and introduces what's coming up. There's no switch for her.")
                    .font(TVType.rowDetail)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(TVPalette.violet.opacity(0.16))
        }
    }

    private func toggleRow(title: String, detail: String, systemImage: String,
                           isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            TVRemoteLogger.log(category: "settings", event: "setting_toggled",
                               detail: ["setting": title, "value": isOn.wrappedValue])
        } label: {
            TVSettingRowLabel(title: title, detail: detail,
                              systemImage: systemImage, isOn: isOn.wrappedValue)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    /// The preset families from the core's catalogue as chips; the chosen
    /// preset's tagline underneath.
    private var eqPresetRow: some View {
        let presets = eqPresets().filter { $0.category == "Signature" || $0.category == "Genre" }
        let current = presets.first { $0.id == settings.eqPresetID }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Preset · \(current?.name ?? "Custom")")
                .font(.system(size: 25, weight: .semibold))
            Text(current?.tagline ?? "")
                .font(TVType.rowDetail)
                .foregroundStyle(TVPalette.textTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(presets, id: \.id) { p in
                        Button {
                            settings.eqPresetID = p.id
                            TVRemoteLogger.log(category: "settings", event: "eq_preset_changed", detail: ["preset": p.id])
                        } label: {
                            TVChip(title: p.name, isSelected: settings.eqPresetID == p.id)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var roomRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Room")
                .font(.system(size: 25, weight: .semibold))
            Text("A touch of space around the music, from the engine's reverb.")
                .font(TVType.rowDetail)
                .foregroundStyle(TVPalette.textTertiary)
            HStack(spacing: 16) {
                ForEach(Array(["Off", "Small Room", "Hall"].enumerated()), id: \.offset) { i, name in
                    Button {
                        settings.room = i
                    } label: {
                        TVChip(title: name, isSelected: settings.room == i)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    /// Column count as a chip row rather than a stepper — three fixed choices
    /// are faster to hit directly than to step through, and the current one is
    /// visible without being selected.
    private var columnsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cards per row")
                .font(.system(size: 25, weight: .semibold))
            Text("Applies to albums, artists, genres and search results. Fewer columns means larger artwork.")
                .font(TVType.rowDetail)
                .foregroundStyle(TVPalette.textTertiary)
            HStack(spacing: 16) {
                ForEach([2, 3, 4], id: \.self) { count in
                    Button {
                        settings.gridColumns = count
                        TVRemoteLogger.log(category: "settings", event: "grid_columns_changed",
                                           detail: ["columns": count])
                    } label: {
                        TVChip(title: "\(count)", isSelected: settings.gridColumns == count)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }
}

/// A settings row's appearance, split out so `@Environment(\.isFocused)` is read
/// inside the button's label — the pattern every custom control in this port
/// uses.
private struct TVSettingRowLabel: View {
    let title: String
    let detail: String
    let systemImage: String
    let isOn: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isOn ? AnyShapeStyle(TVPalette.brand)
                              : AnyShapeStyle(Color.white.opacity(0.1)))
                }

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 25, weight: .semibold))
                Text(detail)
                    .font(TVType.rowDetail)
                    .foregroundStyle(isFocused ? TVPalette.textSecondary : TVPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 24)

            // A drawn switch rather than SwiftUI's `Toggle`: on tvOS a Toggle
            // inside a custom row brings its own focus behaviour and system
            // highlight.
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? AnyShapeStyle(TVPalette.brandHorizontal)
                          : AnyShapeStyle(Color.white.opacity(0.16)))
                    .frame(width: 80, height: 44)
                Circle()
                    .fill(.white)
                    .frame(width: 36, height: 36)
                    .padding(4)
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            }
            .frame(width: 80, height: 44)
            .animation(.spring(response: 0.28, dampingFraction: 0.75), value: isOn)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .tvNeonCard(cornerRadius: 22, isFocused: isFocused, isProminent: false)
    }
}
