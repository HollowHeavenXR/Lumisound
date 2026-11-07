import SwiftUI

/// Builder/editor for a user-created library row style, with a live preview
/// (row + grid forms) that updates as settings change — every control maps
/// directly to a `CustomLibraryRowStyle` field, rendered by the same
/// `CustomLibraryRowView`/`CustomLibraryGridCellView` used throughout the
/// library.
struct LibraryStyleEditorView: View {
    let previewSong: Song?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager
    @State private var draft: CustomLibraryRowStyle
    private let onSave: (CustomLibraryRowStyle) -> Void

    private static let icons = ["list.bullet.rectangle", "rectangle.grid.1x2", "square.stack",
                                 "rectangle.on.rectangle", "circle.grid.2x2", "list.dash"]

    private var samplePreviewSong: Song {
        previewSong ?? Song(title: "Sample Song", artist: "Sample Artist", album: "Sample Album", duration: 214)
    }

    init(style: CustomLibraryRowStyle, previewSong: Song?, onSave: @escaping (CustomLibraryRowStyle) -> Void) {
        _draft = State(initialValue: style)
        self.previewSong = previewSong
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                previewSection
                nameSection
                layoutSection
                artworkSection
                backgroundSection
                typographySection
                spacingSection
                contentSection
                colorsSection
                accentSection
            }
            .navigationTitle("Custom Row Style")
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
            VStack(spacing: 12) {
                CustomLibraryRowView(song: samplePreviewSong, isCurrent: true, config: draft)
                    .environmentObject(library)
                    .environmentObject(player)
                HStack {
                    CustomLibraryGridCellView(song: samplePreviewSong, isCurrent: false, config: draft)
                        .environmentObject(library)
                        .environmentObject(player)
                        .frame(width: 140)
                    Spacer(minLength: 0)
                }
            }
            .listRowBackground(Color.clear)
        } header: {
            Text("Preview")
        } footer: {
            Text("Row form (top) shows the \"now playing\" look; grid form (bottom) shows the normal look.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
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

    // MARK: - Layout

    @ViewBuilder
    private var layoutSection: some View {
        Section("Layout") {
            LumiPicker("Form", selection: $draft.layout) {
                ForEach(CustomLibraryRowStyle.Layout.allCases) { layout in
                    Text(layout.label).lumiOptionLabel(String(describing: layout.label)).tag(layout)
                }
            }
            LumiPicker("Density", selection: $draft.density) {
                ForEach(CustomLibraryRowStyle.Density.allCases) { density in
                    Text(density.label).lumiOptionLabel(String(describing: density.label)).tag(density)
                }
            }
        }
    }

    // MARK: - Artwork

    @ViewBuilder
    private var artworkSection: some View {
        Section("Artwork") {
            LumiPicker("Shape", selection: $draft.artworkShape) {
                ForEach(CustomLibraryRowStyle.ArtworkShape.allCases) { shape in
                    Text(shape.label).lumiOptionLabel(String(describing: shape.label)).tag(shape)
                }
            }
            if draft.artworkShape == .rounded {
                VStack(alignment: .leading) {
                    Text("Corner Radius: \(Int(draft.artworkCornerRadius))")
                        .font(.caption).foregroundStyle(AppTheme.textSecondary)
                    Slider(value: $draft.artworkCornerRadius, in: 0...24, step: 1)
                }
            }
            VStack(alignment: .leading) {
                Text("Size: \(Int(draft.artworkSize))")
                    .font(.caption).foregroundStyle(AppTheme.textSecondary)
                Slider(value: $draft.artworkSize, in: 28...72, step: 2)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentSection: some View {
        Section("Content") {
            LumiPicker("Title Weight", selection: $draft.titleWeight) {
                ForEach(CustomLibraryRowStyle.TitleWeight.allCases) { weight in
                    Text(weight.label).lumiOptionLabel(String(describing: weight.label)).tag(weight)
                }
            }
            Toggle("Show Subtitle", isOn: $draft.showSubtitle)
            Toggle("Show Duration", isOn: $draft.showDuration)
            if draft.layout == .row {
                Toggle("Show Divider", isOn: $draft.showDivider)
            }
        }
    }

    // MARK: - Accent

    @ViewBuilder
    private var accentSection: some View {
        Section {
            LumiPicker("Usage", selection: $draft.accentUsage) {
                ForEach(CustomLibraryRowStyle.AccentUsage.allCases) { usage in
                    Text(usage.label).lumiOptionLabel(String(describing: usage.label)).tag(usage)
                }
            }
        } header: {
            Text("Now-Playing Accent")
        } footer: {
            Text("Controls how the currently-playing track is highlighted.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    // MARK: - Background treatment

    @ViewBuilder
    private var backgroundSection: some View {
        Section {
            LumiPicker("Treatment", selection: $draft.backgroundTreatment) {
                ForEach(CustomLibraryRowStyle.BackgroundTreatment.allCases) { treatment in
                    Text(treatment.label).lumiOptionLabel(String(describing: treatment.label)).tag(treatment)
                }
            }
            VStack(alignment: .leading) {
                Text("Opacity: \(Int(draft.backgroundOpacity * 100))%")
                    .font(.caption).foregroundStyle(AppTheme.textSecondary)
                Slider(value: $draft.backgroundOpacity, in: 0...1, step: 0.05)
            }
            if draft.layout == .card {
                VStack(alignment: .leading) {
                    Text("Card Corner Radius: \(Int(draft.cardCornerRadius))")
                        .font(.caption).foregroundStyle(AppTheme.textSecondary)
                    Slider(value: $draft.cardCornerRadius, in: 0...28, step: 1)
                }
            }
        } header: {
            Text("Background")
        } footer: {
            Text("\"Frosted Glass\" layers a blur under the fill; \"Gradient\" fades the fill toward transparent for subtle depth.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    // MARK: - Typography

    @ViewBuilder
    private var typographySection: some View {
        Section("Typography") {
            VStack(alignment: .leading) {
                Text("Title Size: \(Int(draft.titleFontSize)) pt")
                    .font(.caption).foregroundStyle(AppTheme.textSecondary)
                Slider(value: $draft.titleFontSize, in: 13...24, step: 1)
            }
            VStack(alignment: .leading) {
                Text("Subtitle Size: \(Int(draft.subtitleFontSize)) pt")
                    .font(.caption).foregroundStyle(AppTheme.textSecondary)
                Slider(value: $draft.subtitleFontSize, in: 9...18, step: 1)
            }
            VStack(alignment: .leading) {
                Text("Title Letter Spacing: \(String(format: "%.1f", draft.titleLetterSpacing)) pt")
                    .font(.caption).foregroundStyle(AppTheme.textSecondary)
                Slider(value: $draft.titleLetterSpacing, in: -1...4, step: 0.5)
            }
        }
    }

    // MARK: - Spacing

    @ViewBuilder
    private var spacingSection: some View {
        Section {
            VStack(alignment: .leading) {
                Text("Extra Horizontal Inset: \(Int(draft.horizontalInset)) pt")
                    .font(.caption).foregroundStyle(AppTheme.textSecondary)
                Slider(value: $draft.horizontalInset, in: 0...24, step: 1)
            }
        } header: {
            Text("Spacing")
        } footer: {
            Text("Layered on top of \"Density\" above — lets rows/cards float inward from the screen edges.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    // MARK: - Colors

    @ViewBuilder
    private var colorsSection: some View {
        Section {
            customColorRow(
                label: "Accent Color",
                isCustom: draft.hasCustomAccentColor,
                color: Binding(get: { draft.accentColor }, set: { draft.accentColor = $0 }),
                onToggle: { on in draft.customAccentColorData = on ? CustomLibraryRowStyle.encodeColor(draft.accentColor) : nil }
            )
            customColorRow(
                label: "Title Color",
                isCustom: draft.hasCustomTitleColor,
                color: Binding(get: { draft.titleColor }, set: { draft.titleColor = $0 }),
                onToggle: { on in draft.customTitleColorData = on ? CustomLibraryRowStyle.encodeColor(draft.titleColor) : nil }
            )
            customColorRow(
                label: "Subtitle Color",
                isCustom: draft.hasCustomSubtitleColor,
                color: Binding(get: { draft.subtitleColor }, set: { draft.subtitleColor = $0 }),
                onToggle: { on in draft.customSubtitleColorData = on ? CustomLibraryRowStyle.encodeColor(draft.subtitleColor) : nil }
            )
            if draft.layout == .card {
                customColorRow(
                    label: "Card Background Color",
                    isCustom: draft.hasCustomBackgroundColor,
                    color: Binding(get: { draft.backgroundColor }, set: { draft.backgroundColor = $0 }),
                    onToggle: { on in draft.customBackgroundColorData = on ? CustomLibraryRowStyle.encodeColor(draft.backgroundColor) : nil }
                )
            }
        } header: {
            Text("Colors")
        } footer: {
            Text("Off uses the app's current theme color and follows it automatically if you change themes later. On locks this style to the color you pick.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private func customColorRow(
        label: String,
        isCustom: Bool,
        color: Binding<Color>,
        onToggle: @escaping (Bool) -> Void
    ) -> some View {
        HStack {
            Toggle(isOn: Binding(get: { isCustom }, set: onToggle)) {
                Text(label).foregroundStyle(AppTheme.textPrimary)
            }
            if isCustom {
                ColorPicker("", selection: color, supportsOpacity: true)
                    .labelsHidden()
                    .fixedSize()
            }
        }
    }
}
