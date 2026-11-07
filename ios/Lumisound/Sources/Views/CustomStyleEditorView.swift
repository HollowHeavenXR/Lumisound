import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// Builder/editor for a user-created Now Playing style, with a live
/// preview that updates as settings change — every control maps directly
/// to a `CustomNowPlayingStyle` field, rendered by the same
/// `CustomStyleArtworkView` used in Now Playing itself.
///
/// 2026-07 redesign note: the "Screen Background", "Typography", "Transport
/// Controls", and "Layout & Spacing" sections below are new — they map to
/// `CustomNowPlayingStyle` fields that affect the whole Now Playing screen
/// (via `NowPlayingScreenStyle`, in `NowPlayingStyle.swift`), not just this
/// preview's artwork card.
struct CustomStyleEditorView: View {
    let previewSong: Song?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryManager
    @State private var draft: CustomNowPlayingStyle
    private let onSave: (CustomNowPlayingStyle) -> Void

    @State private var selectedBackgroundImageItem: PhotosPickerItem?
    @State private var showVideoImporter = false

    private static let icons = ["paintpalette.fill", "sparkles", "star.fill", "heart.fill",
                                "bolt.fill", "moon.stars.fill", "flame.fill", "leaf.fill"]

    init(style: CustomNowPlayingStyle, previewSong: Song?, onSave: @escaping (CustomNowPlayingStyle) -> Void) {
        _draft = State(initialValue: style)
        self.previewSong = previewSong
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                previewSection
                nameSection
                backgroundSection
                coverSection
                borderSection
                shadowSection
                decorationSection
                animationSection
                accentSection
                screenBackgroundSection
                typographySection
                controlLayoutSection
                layoutSection
            }
            .navigationTitle("Custom Style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = draft.name.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { draft.name = trimmed }
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var previewSection: some View {
        Section {
            HStack {
                Spacer()
                CustomStyleArtworkView(song: previewSong, isPlaying: true, config: draft)
                    .environmentObject(library)
                    .scaleEffect(0.5)
                    .frame(width: 150, height: 150)
                Spacer()
            }
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Name/Icon

    @ViewBuilder
    private var nameSection: some View {
        Section("Name") {
            TextField("Style name", text: $draft.name)
            LumiPicker("Icon", selection: $draft.iconName) {
                ForEach(Self.icons, id: \.self) { icon in
                    Image(systemName: icon).tag(icon)
                }
            }
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var backgroundSection: some View {
        Section("Background") {
            LumiPicker("Type", selection: $draft.backgroundKind) {
                ForEach(CustomNowPlayingStyle.BackgroundKind.allCases) { kind in
                    Text(kind.label).lumiOptionLabel(String(describing: kind.label)).tag(kind)
                }
            }
            if draft.backgroundKind == .solid {
                ColorPicker("Color", selection: Binding(
                    get: { draft.backgroundColor1.color },
                    set: { draft.backgroundColor1 = CodableColor($0) }
                ))
            } else if draft.backgroundKind == .gradient {
                ColorPicker("Color 1", selection: Binding(
                    get: { draft.backgroundColor1.color },
                    set: { draft.backgroundColor1 = CodableColor($0) }
                ))
                ColorPicker("Color 2", selection: Binding(
                    get: { draft.backgroundColor2.color },
                    set: { draft.backgroundColor2 = CodableColor($0) }
                ))
            }
        }
    }

    // MARK: - Cover

    @ViewBuilder
    private var coverSection: some View {
        Section("Cover") {
            LumiPicker("Shape", selection: $draft.coverShape) {
                ForEach(CustomNowPlayingStyle.CoverShape.allCases) { shape in
                    Text(shape.label).lumiOptionLabel(String(describing: shape.label)).tag(shape)
                }
            }
            if draft.coverShape == .rounded {
                VStack(alignment: .leading) {
                    Text("Corner Radius: \(Int(draft.cornerRadius))")
                        .font(.caption).foregroundStyle(AppTheme.textSecondary)
                    Slider(value: $draft.cornerRadius, in: 0...40, step: 1)
                }
            }
            VStack(alignment: .leading) {
                Text("Size: \(Int(draft.coverSize))")
                    .font(.caption).foregroundStyle(AppTheme.textSecondary)
                Slider(value: $draft.coverSize, in: 120...260, step: 10)
            }
        }
    }

    // MARK: - Border

    @ViewBuilder
    private var borderSection: some View {
        Section("Border") {
            LumiPicker("Style", selection: $draft.borderStyle) {
                ForEach(CustomNowPlayingStyle.BorderStyle.allCases) { style in
                    Text(style.label).lumiOptionLabel(String(describing: style.label)).tag(style)
                }
            }
            if draft.borderStyle != .none {
                Toggle("Use Accent Color", isOn: $draft.borderUsesAccent)
                if !draft.borderUsesAccent {
                    ColorPicker("Color", selection: Binding(
                        get: { draft.borderColor.color },
                        set: { draft.borderColor = CodableColor($0) }
                    ))
                }
            }
        }
    }

    // MARK: - Shadow

    @ViewBuilder
    private var shadowSection: some View {
        Section("Shadow") {
            LumiPicker("Style", selection: $draft.shadowStyle) {
                ForEach(CustomNowPlayingStyle.ShadowStyle.allCases) { style in
                    Text(style.label).lumiOptionLabel(String(describing: style.label)).tag(style)
                }
            }
        }
    }

    // MARK: - Decoration

    @ViewBuilder
    private var decorationSection: some View {
        Section {
            LumiPicker("Effect", selection: $draft.decoration) {
                ForEach(CustomNowPlayingStyle.Decoration.allCases) { deco in
                    Label(deco.label, systemImage: deco.iconName).tag(deco)
                }
            }
        } header: {
            Text("Decoration")
        } footer: {
            if draft.decoration == .waveform {
                Text("Reacts to the actual audio in real time — silent/still when paused.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    // MARK: - Animation

    @ViewBuilder
    private var animationSection: some View {
        Section("Cover Animation") {
            LumiPicker("Animation", selection: $draft.coverAnimation) {
                ForEach(CustomNowPlayingStyle.CoverAnimation.allCases) { anim in
                    Text(anim.label).lumiOptionLabel(String(describing: anim.label)).tag(anim)
                }
            }
            if draft.coverAnimation != .none {
                VStack(alignment: .leading) {
                    Text("Speed: \(String(format: "%.1f", draft.animationSpeed))x")
                        .font(.caption).foregroundStyle(AppTheme.textSecondary)
                    Slider(value: $draft.animationSpeed, in: 0.5...2.0, step: 0.1)
                }
            }
        }
    }

    // MARK: - Accent

    @ViewBuilder
    private var accentSection: some View {
        Section("Accent Color") {
            LumiPicker("Source", selection: $draft.accentSource) {
                ForEach(CustomNowPlayingStyle.AccentSource.allCases) { source in
                    Text(source.label).lumiOptionLabel(String(describing: source.label)).tag(source)
                }
            }
            if draft.accentSource == .custom {
                ColorPicker("Color", selection: Binding(
                    get: { draft.customAccentColor.color },
                    set: { draft.customAccentColor = CodableColor($0) }
                ))
            }
        }
    }

    // MARK: - Screen Background (2026-07 redesign)

    @ViewBuilder
    private var screenBackgroundSection: some View {
        Section {
            VStack(alignment: .leading) {
                Text("Background Blur: \(Int(draft.backgroundBlurRadius))")
                    .font(.caption).foregroundStyle(AppTheme.textSecondary)
                Slider(value: $draft.backgroundBlurRadius, in: 0...40, step: 1)
            }
            VStack(alignment: .leading) {
                Text("Dimming: \(Int(draft.backgroundDimming * 100))%")
                    .font(.caption).foregroundStyle(AppTheme.textSecondary)
                Slider(value: $draft.backgroundDimming, in: 0...0.6, step: 0.05)
            }
            Toggle("Animated Mesh Gradient", isOn: $draft.useMeshGradient)
            Toggle("Use Colors From Artwork", isOn: $draft.dynamicColorExtraction)

            LumiPicker("Custom Media", selection: $draft.customBackgroundMedia) {
                ForEach(CustomNowPlayingStyle.CustomBackgroundMedia.allCases) { media in
                    Text(media.label).lumiOptionLabel(String(describing: media.label)).tag(media)
                }
            }

            if draft.customBackgroundMedia == .image {
                PhotosPicker(selection: $selectedBackgroundImageItem, matching: .images) {
                    Label(draft.customBackgroundImageFilename == nil ? "Choose Image" : "Change Image", systemImage: "photo")
                }
                .onChange(of: selectedBackgroundImageItem) { item in
                    guard let item else { return }
                    Task {
                        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                        let jpegData = BackgroundService.downsampledImage(from: data, maxDimension: 1600)?
                            .jpegData(compressionQuality: 0.85) ?? data
                        await MainActor.run {
                            let oldFilename = draft.customBackgroundImageFilename
                            draft.customBackgroundImageFilename = CustomStyleMediaStore.save(data: jpegData, preferredExtension: "jpg")
                            CustomStyleMediaStore.delete(filename: oldFilename)
                        }
                    }
                }
                if draft.customBackgroundImageFilename != nil {
                    Button("Remove Image", role: .destructive) {
                        CustomStyleMediaStore.delete(filename: draft.customBackgroundImageFilename)
                        draft.customBackgroundImageFilename = nil
                    }
                }
            } else if draft.customBackgroundMedia == .video {
                Button {
                    showVideoImporter = true
                } label: {
                    Label(draft.customBackgroundVideoFilename == nil ? "Choose Video" : "Change Video", systemImage: "video")
                }
                .fileImporter(isPresented: $showVideoImporter, allowedContentTypes: [.movie]) { result in
                    guard case .success(let url) = result else { return }
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    guard let data = try? Data(contentsOf: url) else { return }
                    let oldFilename = draft.customBackgroundVideoFilename
                    let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
                    draft.customBackgroundVideoFilename = CustomStyleMediaStore.save(data: data, preferredExtension: ext)
                    CustomStyleMediaStore.delete(filename: oldFilename)
                }
                if draft.customBackgroundVideoFilename != nil {
                    Button("Remove Video", role: .destructive) {
                        CustomStyleMediaStore.delete(filename: draft.customBackgroundVideoFilename)
                        draft.customBackgroundVideoFilename = nil
                    }
                }
            }

            if draft.customBackgroundMedia != .none {
                VStack(alignment: .leading) {
                    Text("Media Opacity: \(Int(draft.customBackgroundOpacity * 100))%")
                        .font(.caption).foregroundStyle(AppTheme.textSecondary)
                    Slider(value: $draft.customBackgroundOpacity, in: 0.1...1.0, step: 0.05)
                }
            }
        } header: {
            Text("Screen Background")
        } footer: {
            Text("Applies to the whole Now Playing screen, behind the artwork card — separate from the Background section above, which only affects the artwork card itself.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    // MARK: - Typography (2026-07 redesign)

    @ViewBuilder
    private var typographySection: some View {
        Section("Typography") {
            LumiPicker("Title Font", selection: $draft.titleFontChoice) {
                ForEach(CustomNowPlayingStyle.FontChoice.allCases) { choice in
                    Text(choice.label).lumiOptionLabel(String(describing: choice.label)).tag(choice)
                }
            }
            LumiPicker("Title Weight", selection: $draft.titleFontWeight) {
                ForEach(CustomNowPlayingStyle.FontWeightOption.allCases) { weight in
                    Text(weight.label).lumiOptionLabel(String(describing: weight.label)).tag(weight)
                }
            }
            VStack(alignment: .leading) {
                Text("Title Size: \(String(format: "%.2f", draft.titleFontScale))x")
                    .font(.caption).foregroundStyle(AppTheme.textSecondary)
                Slider(value: $draft.titleFontScale, in: 0.7...1.6, step: 0.05)
            }
            Toggle("Custom Title Color", isOn: $draft.titleColorOverrideEnabled)
            if draft.titleColorOverrideEnabled {
                ColorPicker("Title Color", selection: Binding(
                    get: { draft.titleColor.color },
                    set: { draft.titleColor = CodableColor($0) }
                ))
            }

            LumiPicker("Artist Font", selection: $draft.artistFontChoice) {
                ForEach(CustomNowPlayingStyle.FontChoice.allCases) { choice in
                    Text(choice.label).lumiOptionLabel(String(describing: choice.label)).tag(choice)
                }
            }
            LumiPicker("Artist Weight", selection: $draft.artistFontWeight) {
                ForEach(CustomNowPlayingStyle.FontWeightOption.allCases) { weight in
                    Text(weight.label).lumiOptionLabel(String(describing: weight.label)).tag(weight)
                }
            }
            VStack(alignment: .leading) {
                Text("Artist Size: \(String(format: "%.2f", draft.artistFontScale))x")
                    .font(.caption).foregroundStyle(AppTheme.textSecondary)
                Slider(value: $draft.artistFontScale, in: 0.7...1.6, step: 0.05)
            }
            Toggle("Custom Artist Color", isOn: $draft.artistColorOverrideEnabled)
            if draft.artistColorOverrideEnabled {
                ColorPicker("Artist Color", selection: Binding(
                    get: { draft.artistColor.color },
                    set: { draft.artistColor = CodableColor($0) }
                ))
            }
        }
    }

    // MARK: - Transport Controls (2026-07 redesign)

    @ViewBuilder
    private var controlLayoutSection: some View {
        Section {
            Toggle("Custom Controls Color", isOn: $draft.controlsColorOverrideEnabled)
            if draft.controlsColorOverrideEnabled {
                ColorPicker("Controls Color", selection: Binding(
                    get: { draft.controlsColor.color },
                    set: { draft.controlsColor = CodableColor($0) }
                ))
            }
            VStack(alignment: .leading) {
                Text("Control Size: \(String(format: "%.2f", draft.transportControlScale))x")
                    .font(.caption).foregroundStyle(AppTheme.textSecondary)
                Slider(value: $draft.transportControlScale, in: 0.75...1.35, step: 0.05)
            }

            ForEach(Array(draft.transportControlOrder.enumerated()), id: \.element) { index, control in
                HStack {
                    Text(control.label)
                        .foregroundStyle(control == .playPause ? AppTheme.textSecondary : AppTheme.textPrimary)
                    Spacer()
                    if control != .playPause {
                        Toggle("", isOn: Binding(
                            get: { !draft.hiddenTransportControls.contains(control) },
                            set: { isOn in
                                if isOn {
                                    draft.hiddenTransportControls.remove(control)
                                } else {
                                    draft.hiddenTransportControls.insert(control)
                                }
                            }
                        ))
                        .labelsHidden()
                    }
                    Button {
                        moveControl(control, up: true)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)
                    Button {
                        moveControl(control, up: false)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == draft.transportControlOrder.count - 1)
                }
            }
        } header: {
            Text("Transport Controls")
        } footer: {
            Text("Play/Pause always stays visible and centered, regardless of its position here.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private func moveControl(_ control: CustomNowPlayingStyle.TransportControl, up: Bool) {
        guard let idx = draft.transportControlOrder.firstIndex(of: control) else { return }
        let newIdx = up ? idx - 1 : idx + 1
        guard draft.transportControlOrder.indices.contains(newIdx) else { return }
        draft.transportControlOrder.swapAt(idx, newIdx)
    }

    // MARK: - Layout & Spacing (2026-07 redesign)

    @ViewBuilder
    private var layoutSection: some View {
        Section("Layout & Spacing") {
            LumiPicker("Section Spacing", selection: $draft.sectionSpacingDensity) {
                ForEach(CustomNowPlayingStyle.SpacingDensity.allCases) { density in
                    Text(density.label).lumiOptionLabel(String(describing: density.label)).tag(density)
                }
            }
            VStack(alignment: .leading) {
                Text("Panel Corner Radius: \(Int(draft.panelCornerRadius))")
                    .font(.caption).foregroundStyle(AppTheme.textSecondary)
                Slider(value: $draft.panelCornerRadius, in: 0...24, step: 1)
            }
        }
    }
}
