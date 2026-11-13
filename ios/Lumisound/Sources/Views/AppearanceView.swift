import SwiftUI
import UIKit

// MARK: - AppearanceView

struct AppearanceView: View {

    // MARK: State

    /// Used only to source a representative song for the card-style live preview.
    @EnvironmentObject private var library: LibraryManager
    /// Used to push the accent color change to the server immediately — without
    /// this, a color picked here only syncs the next time favorites/playlists/
    /// audio settings change (see `AccountService.pullSync`'s theme-color comment),
    /// so a fresh install on another device could miss it entirely.
    @EnvironmentObject private var account: AccountService
    /// Needed to present `LibraryStyleEditorView`/`LibraryStyleManagerView`
    /// as sheets with a full environment (they render `SongContextMenuContent`).
    @EnvironmentObject private var player: AudioPlayerManager

    @State private var customColor: Color = AppTheme.dynamicAccent
    @State private var customSecondaryColor: Color = AppTheme.dynamicAccentSecondary
    @State private var refreshToken = UUID()

    @AppStorage("panel_opacity")             private var panelOpacity: Double = 1.0
    @AppStorage("nowPlaying_artworkStyle")   private var artworkStyleRaw: String = NowPlayingArtworkStyle.kaleidoscopeBloom.rawValue
    @AppStorage("nowPlaying_seekerStyle")    private var seekerStyleRaw: String  = SeekerStyle.waveform.rawValue
    @AppStorage("library_cardStyle")         private var cardStyleRaw: String    = SongCardStyle.compact.rawValue
    @AppStorage("app_background_theme")      private var backgroundThemeRaw: String = AppBackgroundTheme.default.rawValue
    @AppStorage("app_font_style")            private var fontStyleRaw: String   = AppFontStyle.system.rawValue
    @AppStorage("launch_screen_style")       private var launchScreenStyleRaw: String = LaunchScreenStyle.aurora.rawValue
    @AppStorage("tab_transition_style")      private var tabTransitionStyleRaw: String = TabTransitionStyle.scalePop.rawValue
    @AppStorage("panel_material_style")      private var panelMaterialRaw: String = PanelMaterialStyle.solid.rawValue
    @AppStorage("app_reduce_motion")         private var reduceMotion: Bool = false

    // Song Card style — the same String-selection pattern as Now Playing's
    // artwork style: either a built-in `SongCardStyle` rawValue or a
    // user-created `CustomLibraryRowStyle`'s UUID.
    @ObservedObject private var customLibraryStyleStore = CustomLibraryStyleStore.shared
    @ObservedObject private var hiddenCardStylesStore = HiddenCardStylesStore.shared
    @State private var editingCustomLibraryStyle: CustomLibraryRowStyle?
    @State private var showLibraryStyleManager = false

    private var visibleBuiltinCardStyles: [SongCardStyle] {
        SongCardStyle.allCases.filter { !hiddenCardStylesStore.isHidden($0.rawValue) }
    }

    // MARK: Preset Swatches

    private struct PresetSwatch: Identifiable {
        let id = UUID()
        let name: String
        let color: Color
    }

    private let presetSwatches: [PresetSwatch] = [
        .init(name: "Pink",    color: Color(red: 0.925, green: 0.251, blue: 0.478)),
        .init(name: "Blue",    color: Color(red: 0.255, green: 0.533, blue: 0.961)),
        .init(name: "Purple",  color: Color(red: 0.588, green: 0.290, blue: 0.878)),
        .init(name: "Green",   color: Color(red: 0.208, green: 0.780, blue: 0.349)),
        .init(name: "Orange",  color: Color(red: 0.988, green: 0.549, blue: 0.133)),
        .init(name: "Yellow",  color: Color(red: 0.988, green: 0.820, blue: 0.200)),
        .init(name: "Teal",    color: Color(red: 0.180, green: 0.757, blue: 0.729)),
        .init(name: "Red",     color: Color(red: 0.961, green: 0.220, blue: 0.220)),
    ]

    // MARK: Body

    var body: some View {
        content
            .onDisappear { Appearance.shared.commitPalette() }
    }

    enum Shelf: String, CaseIterable { case colour = "Colour", surfaces = "Surfaces", player = "Player", motion = "Motion" }
    @AppStorage("appearance.shelf") private var shelfRaw = Shelf.colour.rawValue
    private var shelf: Shelf { Shelf(rawValue: shelfRaw) ?? .colour }

    private var content: some View {
        LKPage(title: "Appearance", subtitle: "Colour, surfaces, the player and motion.", icon: "paintbrush.fill", tint: AppTheme.dynamicAccent) {
            accentPreviewRow
                .padding(14)
                .background(LKCardBackground(tint: AppTheme.dynamicAccent))
            LKSegmented(options: Shelf.allCases.map { ($0, $0.rawValue) }, selection: Binding(
                get: { shelf }, set: { shelfRaw = $0.rawValue }))
            Group {
                switch shelf {
                case .colour: colourShelf
                case .surfaces: surfacesShelf
                case .player: playerShelf
                case .motion: motionShelf
                }
            }
            .transition(.opacity)
            resetButton
        }
        .id(refreshToken)
        .animation(LumiMotion.fade(0.2), value: shelfRaw)
        .onAppear {
            customColor = AppTheme.dynamicAccent
            customSecondaryColor = AppTheme.dynamicAccentSecondary
        }
    }

    @ViewBuilder
    private var colourShelf: some View {
        LKCard(title: "Quick picks") { presetSwatchGrid.padding(.vertical, 4) }
        LKCard(title: "Your own", footer: "The second colour pairs with your accent wherever a gradient is shown — the mini player and launch screen.") {
            HStack(spacing: 12) {
                LKIcon(symbol: "eyedropper.halffull", tint: customColor)
                ColorPicker("Accent", selection: $customColor, supportsOpacity: false)
                    .foregroundStyle(AppTheme.textPrimary)
                    .onChange(of: customColor) { newColor in
                        AppTheme.saveAccentColor(newColor)
                        refreshToken = UUID()
                        account.schedulePush(library: library)
                    }
            }
            .padding(.vertical, 6)
            LKDivider()
            HStack(spacing: 12) {
                LKIcon(symbol: "circle.lefthalf.filled", tint: customSecondaryColor)
                ColorPicker("Gradient partner", selection: $customSecondaryColor, supportsOpacity: false)
                    .foregroundStyle(AppTheme.textPrimary)
                    .onChange(of: customSecondaryColor) { newColor in
                        AppTheme.saveAccentSecondaryColor(newColor)
                        refreshToken = UUID()
                    }
            }
            .padding(.vertical, 6)
        }
        LKCard(title: "Background theme", footer: "Background and surface colours everywhere.") { backgroundThemePicker }
        LKCard(title: "Font") { fontStylePicker }
    }

    @ViewBuilder
    private var surfacesShelf: some View {
        LKCard(title: "Interface style", footer: "How cards, panels and the player chrome are drawn. Synced to your account.") {
            AppearanceStylePicker()
        }
        LKCard(title: "Panels") {
            panelOpacityRow
            LKDivider()
            HStack(spacing: 12) {
                LKIcon(symbol: "square.on.square", tint: .purple)
                LumiPicker(selection: $panelMaterialRaw) {
                    ForEach(PanelMaterialStyle.allCases) { style in
                        Text(style.displayName).lumiOptionLabel(String(describing: style.displayName)).tag(style.rawValue)
                    }
                } label: {
                    Text("Panel material").foregroundStyle(AppTheme.textPrimary)
                }
            }
            .padding(.vertical, 6)
        }
        LKCard(title: "Song cards", footer: "How song rows look in Library, Queue, Favorites, Playlists and Artists.") { cardStylePicker }
    }

    @ViewBuilder
    private var playerShelf: some View {
        LKCard(title: "Now Playing defaults", footer: "The starting style for new sessions. You can still switch live in Now Playing.") {
            artworkStylePicker
            LKDivider(inset: 0)
            seekerStylePicker
        }
    }

    @ViewBuilder
    private var motionShelf: some View {
        LKCard {
            LKToggle(icon: "figure.walk.motion", tint: .green, title: "Reduce Motion",
                     subtitle: "Simpler launch screen and background transitions", isOn: $reduceMotion)
        }
        LKCard(title: "Launch screen", footer: "Minimalist skips the animated halo — also used when Reduce Motion is on.") {
            LKSegmented(options: LaunchScreenStyle.allCases.map { ($0.rawValue, $0.displayName) }, selection: $launchScreenStyleRaw)
                .padding(.vertical, 4)
        }
        LKCard(title: "Switching tabs") {
            LKSegmented(options: TabTransitionStyle.allCases.map { ($0.rawValue, $0.displayName) }, selection: $tabTransitionStyleRaw)
                .padding(.vertical, 4)
        }
    }

    private var resetButton: some View {
        LKPrimaryButton(title: "Reset Appearance", icon: "arrow.counterclockwise", tint: .gray, prominent: false) {
            AppTheme.resetAccentColor()
            AppTheme.resetAccentSecondaryColor()
            AppTheme.resetBackgroundTheme()
            AppTheme.resetFontStyle()
            customColor = AppTheme.accent
            customSecondaryColor = AppTheme.accentSoft
            backgroundThemeRaw = AppBackgroundTheme.default.rawValue
            fontStyleRaw = AppFontStyle.system.rawValue
            panelMaterialRaw = PanelMaterialStyle.solid.rawValue
            launchScreenStyleRaw = LaunchScreenStyle.aurora.rawValue
            tabTransitionStyleRaw = TabTransitionStyle.scalePop.rawValue
            reduceMotion = false
            panelOpacity = 1.0
            refreshToken = UUID()
            account.schedulePush(library: library)
            ToastCenter.shared.show("Appearance reset to default", category: .info, icon: "arrow.counterclockwise")
        }
    }

    // MARK: — Subviews

    private var accentPreviewRow: some View {
        let current = AppTheme.dynamicAccent

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Circle()
                    .fill(current)
                    .frame(width: 44, height: 44)
                    .shadow(color: current.opacity(0.5), radius: 6, x: 0, y: 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Accent Color")
                        .font(AppTheme.headlineFont())
                        .foregroundStyle(AppTheme.textPrimary)
                    Text("Used in tabs, toggles, and highlights")
                        .font(AppTheme.bodyFont(size: 13))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Image(systemName: "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(current)

                Capsule()
                    .fill(current)
                    .frame(width: 44, height: 26)
                    .overlay(
                        Circle()
                            .fill(Color.white)
                            .frame(width: 22, height: 22)
                            .offset(x: 9)
                    )

                Text("Now Playing")
                    .font(AppTheme.bodyFont(size: 13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(current.opacity(0.2), in: Capsule())
                    .foregroundStyle(current)

                Spacer()
            }
        }
        .padding(.vertical, 6)
    }

    private var presetSwatchGrid: some View {
        let current = AppTheme.dynamicAccent

        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
            spacing: 14
        ) {
            ForEach(presetSwatches) { swatch in
                Button {
                    AppTheme.saveAccentColor(swatch.color)
                    customColor = swatch.color
                    refreshToken = UUID()
                    account.schedulePush(library: library)
                    ToastCenter.shared.show("Accent color set to \(swatch.name)", category: .success, icon: "paintbrush.fill")
                } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .fill(swatch.color)
                                .frame(width: 44, height: 44)
                                .shadow(color: swatch.color.opacity(0.4), radius: 4, x: 0, y: 2)

                            if colorMatches(swatch.color, current) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }

                        Text(swatch.name)
                            .font(AppTheme.monoFont(size: 10))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }

    private var backgroundThemePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(AppBackgroundTheme.allCases) { theme in
                    let isSelected = backgroundThemeRaw == theme.rawValue
                    Button {
                        backgroundThemeRaw = theme.rawValue
                        refreshToken = UUID()
                    } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .fill(theme.background)
                                    .frame(width: 40, height: 40)
                                Circle()
                                    .fill(theme.elevatedSurface)
                                    .frame(width: 18, height: 18)
                                    .offset(x: 10, y: 10)
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .overlay(
                                Circle()
                                    .strokeBorder(isSelected ? AppTheme.dynamicAccent : .clear, lineWidth: 2)
                                    .frame(width: 46, height: 46)
                            )
                            Text(theme.displayName)
                                .font(AppTheme.monoFont(size: 10))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var fontStylePicker: some View {
        HStack(spacing: 8) {
            ForEach(AppFontStyle.allCases) { style in
                let isSelected = fontStyleRaw == style.rawValue
                Button {
                    fontStyleRaw = style.rawValue
                    refreshToken = UUID()
                } label: {
                    Text("Aa")
                        .font(.system(size: 16, weight: .semibold, design: style.design))
                        .foregroundStyle(isSelected ? .white : AppTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            isSelected ? AppTheme.dynamicAccent : AppTheme.elevatedSurface,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var artworkStylePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Default Artwork Style")
                .font(AppTheme.bodyFont())
                .foregroundStyle(AppTheme.textPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(NowPlayingArtworkStyle.allCases) { style in
                        Button {
                            artworkStyleRaw = style.rawValue
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: style.iconName)
                                    .font(.system(size: 13, weight: .medium))
                                Text(style.displayName)
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(artworkStyleRaw == style.rawValue ? .white : AppTheme.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                artworkStyleRaw == style.rawValue ? AppTheme.dynamicAccent : AppTheme.elevatedSurface,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .animation(LumiMotion.fade(0.15), value: artworkStyleRaw)
                    }
                }
                .padding(.bottom, 2)
            }
        }
        .padding(.vertical, 6)
    }

    private var cardStylePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Song Row Style")
                .font(AppTheme.bodyFont())
                .foregroundStyle(AppTheme.textPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(visibleBuiltinCardStyles) { style in
                        cardStyleChip(
                            icon: style.iconName, name: style.displayName,
                            isSelected: cardStyleRaw == style.rawValue
                        ) {
                            cardStyleRaw = style.rawValue
                        }
                    }
                    ForEach(customLibraryStyleStore.styles) { custom in
                        cardStyleChip(
                            icon: custom.iconName, name: custom.name,
                            isSelected: cardStyleRaw == custom.id
                        ) {
                            cardStyleRaw = custom.id
                        }
                        .contextMenu {
                            Button {
                                editingCustomLibraryStyle = custom
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                customLibraryStyleStore.remove(id: custom.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.bottom, 2)
            }

            // Live preview using a representative row in the chosen style.
            if let previewSong = library.allSongs.first {
                SongRow(song: previewSong, isCurrent: false)
                    .id(cardStyleRaw)
                    .padding(.top, 2)
            }

            // Always-visible (never requires scrolling the chip row to find,
            // unlike the small trailing chips this replaced) entry points for
            // creating and managing custom row styles.
            HStack(spacing: 10) {
                Button {
                    editingCustomLibraryStyle = CustomLibraryRowStyle()
                } label: {
                    Label("New Style", systemImage: "plus.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.dynamicAccent)

                Button {
                    showLibraryStyleManager = true
                } label: {
                    Label("Manage Styles", systemImage: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.textSecondary)

                Spacer(minLength: 0)
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 6)
        .sheet(item: $editingCustomLibraryStyle) { style in
            LibraryStyleEditorView(style: style, previewSong: library.allSongs.first) { saved in
                customLibraryStyleStore.update(saved)
                cardStyleRaw = saved.id
            }
            .environmentObject(library)
            .environmentObject(player)
        }
        .sheet(isPresented: $showLibraryStyleManager) {
            LibraryStyleManagerView()
                .environmentObject(library)
                .environmentObject(player)
        }
    }

    private func cardStyleChip(icon: String, name: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                Text(name)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(isSelected ? .white : AppTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isSelected ? AppTheme.dynamicAccent : AppTheme.elevatedSurface,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .animation(LumiMotion.fade(0.15), value: isSelected)
    }

    private var seekerStylePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Default Seeker Style")
                .font(AppTheme.bodyFont())
                .foregroundStyle(AppTheme.textPrimary)

            HStack(spacing: 8) {
                ForEach(SeekerStyle.allCases) { style in
                    Button {
                        seekerStyleRaw = style.rawValue
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: style.iconName)
                                .font(.system(size: 13, weight: .medium))
                            Text(style.displayName)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(seekerStyleRaw == style.rawValue ? .white : AppTheme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            seekerStyleRaw == style.rawValue ? AppTheme.dynamicAccent : AppTheme.elevatedSurface,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .animation(LumiMotion.fade(0.15), value: seekerStyleRaw)
                }
                Spacer()
            }
        }
        .padding(.vertical, 6)
    }

    private var panelOpacityRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Panel Opacity")
                    .font(AppTheme.bodyFont())
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text(String(format: "%.0f%%", panelOpacity * 100))
                    .font(AppTheme.monoFont())
                    .foregroundStyle(AppTheme.textSecondary)
                    .monospacedDigit()
            }
            Slider(value: $panelOpacity, in: 0.2...1.0)
                .tint(AppTheme.dynamicAccent)

            // Mini preview panel
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16))
                    .foregroundStyle(AppTheme.dynamicAccent)
                Text("Panel preview")
                    .font(AppTheme.bodyFont(size: 13))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .padding(12)
            .background(
                AppTheme.surface.opacity(panelOpacity),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .padding(.vertical, 6)
    }

    // MARK: Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(AppTheme.bodyFont())
            .foregroundStyle(AppTheme.textSecondary)
    }

    private func colorMatches(_ a: Color, _ b: Color) -> Bool {
        let ua = UIColor(a), ub = UIColor(b)
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        ua.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        ub.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let threshold: CGFloat = 0.02
        return abs(r1 - r2) < threshold
            && abs(g1 - g2) < threshold
            && abs(b1 - b2) < threshold
    }
}
