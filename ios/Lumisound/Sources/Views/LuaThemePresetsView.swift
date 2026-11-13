import SwiftUI
import UIKit

// MARK: - LuaThemePresetsView
//
// Runtime preset switcher for the Lua-scripted theming/logic layer (see
// `Theme/LuaThemeEngine.swift`). Follows the same list-of-tappable-swatches
// + toast-on-select pattern `AppearanceView`'s "Background Theme" and "Quick
// Picks" sections already use, so applying a Lua preset feels like just
// another built-in appearance option rather than a bolted-on system.

struct LuaThemePresetsView: View {
    @ObservedObject private var engine = LuaThemeEngine.shared
    @State private var refreshToken = UUID()
    @State private var userPresets: [URL] = LuaThemeEngine.shared.userPresetScripts()
    @State private var showImportSheet = false
    @State private var importText = ""
    @State private var importName = ""

    var body: some View {
        LKPage(title: "Lua Themes", subtitle: "Script-driven colour presets.", icon: "scroll.fill", tint: .orange) {
            LKSection {
                Text("Each preset is a small Lua script that sets the app's colors, fonts, panel/glass style, a few behavior flags, and the Library tab's default sort — all in one tap. Applying one overwrites the individual choices in Appearance, Liquid Glass, and the Library sort chips.")
                    .font(AppTheme.bodyFont(size: 13))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            if let error = engine.lastError {
                LKSection {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(AppTheme.bodyFont(size: 13))
                        .foregroundStyle(AppTheme.error)
                }
            }

            LKSection {
                ForEach(LuaPreset.allCases) { preset in
                    presetRow(preset)
                }
            } header: {
                sectionHeader("Presets")
            }

            LKSection {
                if userPresets.isEmpty {
                    Text("No imported presets yet. Tap Import above to paste one someone shared with you.")
                        .font(AppTheme.bodyFont(size: 13))
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    ForEach(userPresets, id: \.self) { url in
                        userPresetRow(url)
                    }
                }
            } header: {
                sectionHeader("Imported (Community)")
            }

            if engine.activePresetID != nil {
                LKSection {
                    Button(role: .destructive) {
                        engine.clearPreset()
                        refreshToken = UUID()
                        ToastCenter.shared.show("Lua preset cleared", category: .info, icon: "arrow.counterclockwise")
                    } label: {
                        HStack {
                            Image(systemName: "xmark.circle")
                            Text("Clear Active Preset")
                        }
                    }
                    .foregroundStyle(AppTheme.dynamicAccent)
                }
                LKSection {
                    Text("Clearing only removes the preset marker and the custom background/layout scale it set — individual colors, fonts, and styles stay as the preset left them. Use Appearance → Reset to Default to restore everything.")
                        .font(AppTheme.bodyFont(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
        .id(refreshToken)
        .background(Color.clear.ignoresSafeArea())
        .navigationTitle("Lua Theme Presets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    importText = UIPasteboard.general.string ?? ""
                    importName = ""
                    showImportSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
            }
        }
        .sheet(isPresented: $showImportSheet) {
            importSheet
        }
    }

    private func userPresetRow(_ url: URL) -> some View {
        let isActive = engine.activeUserScriptURL == url
        let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ").capitalized

        return Button {
            let ok = engine.applyUserScript(at: url)
            refreshToken = UUID()
            if ok {
                ToastCenter.shared.show("Applied \u{201C}\(name)\u{201D}", category: .success, icon: "square.and.arrow.down")
            } else {
                ToastCenter.shared.show(engine.lastError ?? "Couldn't apply that preset", category: .error, icon: "exclamationmark.triangle.fill")
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(url.lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.dynamicAccent)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                engine.deleteUserPreset(at: url)
                userPresets = engine.userPresetScripts()
                refreshToken = UUID()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var importSheet: some View {
        NavigationStack {
            LKScroll {
                LKSection("Preset Name") {
                    TextField("e.g. my_theme", text: $importName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                LKSection("Lua Source") {
                    TextEditor(text: $importText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 220)
                }
                LKSection {
                    Text("Paste a preset script someone shared with you — it must set a global `theme` table (see any bundled preset for the exact shape).")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .navigationTitle("Import Theme Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showImportSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        do {
                            let name = importName.trimmingCharacters(in: .whitespaces)
                            try engine.importUserPreset(source: importText, suggestedName: name.isEmpty ? "custom_theme" : name)
                            userPresets = engine.userPresetScripts()
                            showImportSheet = false
                            ToastCenter.shared.show("Imported preset", category: .success, icon: "square.and.arrow.down")
                        } catch {
                            ToastCenter.shared.show("Couldn't import preset: \(error.localizedDescription)", category: .error, icon: "exclamationmark.triangle.fill")
                        }
                    }
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func presetRow(_ preset: LuaPreset) -> some View {
        let isActive = engine.activePresetID == preset.rawValue
        let swatches = preset.previewColors

        return Button {
            let ok = engine.apply(preset)
            refreshToken = UUID()
            if ok {
                ToastCenter.shared.show("Applied “\(preset.displayName)”", category: .success, icon: preset.iconName)
            } else {
                ToastCenter.shared.show(engine.lastError ?? "Couldn't apply that preset", category: .error, icon: "exclamationmark.triangle.fill")
            }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(swatches.background)
                        .frame(width: 40, height: 40)
                    Circle()
                        .fill(swatches.accent)
                        .frame(width: 18, height: 18)
                        .offset(x: 10, y: 10)
                }
                .overlay(
                    Circle()
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                        .frame(width: 40, height: 40)
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.displayName)
                        .font(AppTheme.headlineFont(size: 15))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(preset.subtitle)
                        .font(AppTheme.bodyFont(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                }

                Spacer()

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.dynamicAccent)
                } else {
                    Image(systemName: preset.iconName)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(AppTheme.bodyFont())
            .foregroundStyle(AppTheme.textSecondary)
    }
}
