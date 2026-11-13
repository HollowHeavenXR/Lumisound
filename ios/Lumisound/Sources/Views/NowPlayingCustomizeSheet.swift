import SwiftUI
import UIKit

// MARK: - NowPlayingCustomizeSheet
//
// Every Now Playing look option in one place. Before the 2026-09
// restructure these were three chip rows on the screen itself — 26+ artwork
// styles under the cover, then 12 seeker styles and 6 counter formats under
// the scrubber — so most of the first screenful was pickers. The sheet opens
// at a medium detent, leaving the artwork visible above it as a live
// preview while styles are tried.
//
// It edits the same storage as before (the `nowPlaying_*` keys, custom
// styles in `CustomStyleStore`, hidden built-ins in `HiddenStylesStore`),
// so Appearance settings, Lua theme presets and sync all still apply.

struct NowPlayingCustomizeSheet: View {
    /// The selection when the sheet opened; tracked locally from then on so
    /// the checkmark moves immediately.
    let artworkStyleSelection: String
    @Binding var seekerStyle: SeekerStyle
    @Binding var playtimeCounterStyle: PlaytimeCounterStyle
    let accent: Color
    let onSelectArtworkStyle: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var library: LibraryManager
    @ObservedObject private var customStyleStore = CustomStyleStore.shared
    @ObservedObject private var hiddenStylesStore = HiddenStylesStore.shared

    @State private var selection: String = ""
    @State private var editingCustomStyle: CustomNowPlayingStyle?
    @State private var showStyleManager = false

    private let haptic = UISelectionFeedbackGenerator()

    private var visibleBuiltinStyles: [NowPlayingArtworkStyle] {
        NowPlayingArtworkStyle.allCases.filter { !hiddenStylesStore.isHidden($0.rawValue) }
    }

    private let tileColumns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3)
    private let chipColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    artworkSection
                    seekerSection
                    counterSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Customize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .tint(accent)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .onAppear {
            selection = artworkStyleSelection
            haptic.prepare()
        }
        .sheet(item: $editingCustomStyle) { style in
            CustomStyleEditorView(style: style, previewSong: player.currentSong) { saved in
                customStyleStore.update(saved)
                select(saved.id)
            }
            .environmentObject(library)
        }
        .sheet(isPresented: $showStyleManager) {
            StyleManagerView()
                .environmentObject(library)
        }
    }

    private func select(_ id: String) {
        haptic.selectionChanged()
        selection = id
        withAnimation(LumiMotion.fade(0.25)) {
            onSelectArtworkStyle(id)
        }
    }

    // MARK: Artwork

    private var artworkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Artwork Style", icon: "photo.artframe", trailing: "\(visibleBuiltinStyles.count + customStyleStore.styles.count)")

            LazyVGrid(columns: tileColumns, spacing: 10) {
                ForEach(visibleBuiltinStyles) { style in
                    styleTile(name: style.displayName, icon: style.iconName, isSelected: selection == style.rawValue) {
                        select(style.rawValue)
                    }
                }
                ForEach(customStyleStore.styles) { custom in
                    styleTile(name: custom.name, icon: custom.iconName, isSelected: selection == custom.id, isCustom: true) {
                        select(custom.id)
                    }
                    .contextMenu {
                        Button {
                            editingCustomStyle = custom
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            customStyleStore.remove(id: custom.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                actionTile(name: "New Style", icon: "plus", dashed: true) {
                    editingCustomStyle = CustomNowPlayingStyle()
                }
                actionTile(name: "Manage", icon: "slider.horizontal.3", dashed: false) {
                    showStyleManager = true
                }
            }

            Text("Long-press a custom style to edit it. Hidden styles can be shown again from Manage.")
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private func styleTile(
        name: String,
        icon: String,
        isSelected: Bool,
        isCustom: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            isSelected
                                ? AnyShapeStyle(LinearGradient(
                                    colors: [accent, accent.opacity(0.55)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ))
                                : AnyShapeStyle(AppTheme.surface.opacity(0.7))
                        )
                        .aspectRatio(1.35, contentMode: .fit)
                        .overlay {
                            Image(systemName: icon)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(isSelected ? .white : accent)
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(isSelected ? .white.opacity(0.35) : AppTheme.textSecondary.opacity(0.12), lineWidth: 1)
                        )

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15, weight: .bold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(accent, .white)
                            .padding(6)
                    } else if isCustom {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.textSecondary)
                            .padding(6)
                    }
                }
                Text(name)
                    .font(.caption2.weight(isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? AppTheme.textPrimary : AppTheme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(LumiMotion.fade(0.18), value: isSelected)
    }

    private func actionTile(name: String, icon: String, dashed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.clear)
                    .aspectRatio(1.35, contentMode: .fit)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                accent.opacity(0.55),
                                style: StrokeStyle(lineWidth: 1.2, dash: dashed ? [5, 4] : [])
                            )
                    )
                Text(name)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
            }
        }
        .buttonStyle(PressableButtonStyle())
    }

    // MARK: Seeker

    private var seekerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Seeker", icon: "slider.horizontal.below.rectangle", trailing: nil)

            LazyVGrid(columns: chipColumns, spacing: 8) {
                ForEach(SeekerStyle.allCases) { style in
                    optionChip(name: style.displayName, icon: style.iconName, isSelected: seekerStyle == style) {
                        haptic.selectionChanged()
                        withAnimation(LumiMotion.fade(0.2)) { seekerStyle = style }
                    }
                }
            }

            if seekerStyle == .custom {
                CustomScrubberSettingsPanel()
                    .padding(12)
                    .background(AppTheme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: Time display

    private var counterSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Time Display", icon: "clock", trailing: nil)

            LazyVGrid(columns: chipColumns, spacing: 8) {
                ForEach(PlaytimeCounterStyle.allCases) { style in
                    optionChip(name: style.displayName, icon: style.iconName, isSelected: playtimeCounterStyle == style) {
                        haptic.selectionChanged()
                        withAnimation(LumiMotion.fade(0.2)) { playtimeCounterStyle = style }
                    }
                }
            }

            Text("An extra readout under the seeker. The seeker shows elapsed and remaining time on its own; tap the readout on Now Playing to switch format.")
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    // MARK: Pieces

    private func sectionHeader(_ title: String, icon: String, trailing: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent)
            Text(title)
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
            if let trailing {
                Text(trailing)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
        }
    }

    private func optionChip(name: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                Text(name)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(isSelected ? .white : AppTheme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .background(
                isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(AppTheme.surface.opacity(0.7)),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(LumiMotion.fade(0.18), value: isSelected)
    }
}
