import SwiftUI
import UIKit

// MARK: - LuaVisualizerScriptsView
//
// Picker + community-sharing UI for Lua-scripted "Live Spectrum" visualizer
// styles (see `LuaVisualizerEngine`/`LuaVisualizerStore`). Same list-of-rows
// + apply + import pattern as `LuaEffectScriptsView`/`LuaThemePresetsView`.
struct LuaVisualizerScriptsView: View {
    @ObservedObject private var store = LuaVisualizerStore.shared

    @State private var bundled: [LuaUserScriptLibrary.ScriptRef] = LuaVisualizerEngine.bundledScripts()
    @State private var userScripts: [LuaUserScriptLibrary.ScriptRef] = LuaVisualizerEngine.userScripts()
    @State private var showImportSheet = false
    @State private var importText = ""
    @State private var importName = ""

    var body: some View {
        LKPage(title: "Scripted Visualizer", subtitle: "Lua scripts that draw to your music.", icon: "waveform.path.ecg.rectangle", tint: .pink) {
            LKSection {
                Text("Restyles the \u{201C}Live Spectrum\u{201D} Now Playing artwork style — the real-time FFT analysis stays native, but a script controls the gradient colors, sensitivity, bar spacing/rounding, and mirroring. Select \u{201C}Live Spectrum\u{201D} under artwork styles to see it.")
                    .font(AppTheme.bodyFont(size: 13))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            if let error = store.lastError {
                LKSection {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(AppTheme.bodyFont(size: 13))
                        .foregroundStyle(AppTheme.error)
                }
            }

            LKSection {
                ForEach(bundled) { ref in
                    scriptRow(ref)
                }
            } header: {
                Text("Bundled Examples")
            }

            LKSection {
                if userScripts.isEmpty {
                    Text("No imported scripts yet.")
                        .font(AppTheme.bodyFont(size: 13))
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    ForEach(userScripts) { ref in
                        scriptRow(ref)
                            .contextMenu {
                                Button(role: .destructive) {
                                    LuaVisualizerEngine.deleteUserScript(ref)
                                    userScripts = LuaVisualizerEngine.userScripts()
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            } header: {
                Text("Imported")
            }

            if store.activeScriptID != nil {
                LKSection {
                    Button(role: .destructive) {
                        store.clear()
                        ToastCenter.shared.show("Visualizer style cleared", category: .info, icon: "arrow.counterclockwise")
                    } label: {
                        Label("Use Default Style", systemImage: "xmark.circle")
                    }
                    .foregroundStyle(AppTheme.dynamicAccent)
                }
            }
        }
        .background(Color.clear.ignoresSafeArea())
        .navigationTitle("Scripted Visualizer")
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

    private func scriptRow(_ ref: LuaUserScriptLibrary.ScriptRef) -> some View {
        Button {
            let ok = store.apply(ref)
            if ok {
                ToastCenter.shared.show("Applied \u{201C}\(ref.displayName)\u{201D}", category: .success, icon: "waveform.path.ecg.rectangle")
            } else {
                ToastCenter.shared.show(store.lastError ?? "Couldn't apply that visualizer script", category: .error, icon: "exclamationmark.triangle.fill")
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ref.displayName)
                        .foregroundStyle(AppTheme.textPrimary)
                    Text("\(ref.id).lua")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                if store.activeScriptID == ref.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.dynamicAccent)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var importSheet: some View {
        NavigationStack {
            LKScroll {
                LKSection("Script Name") {
                    TextField("e.g. my_visualizer", text: $importName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                LKSection("Lua Source") {
                    TextEditor(text: $importText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 220)
                }
                LKSection {
                    Text("Paste a script someone shared with you — it must set a global `visualizer` table (see the bundled examples for the exact shape).")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .navigationTitle("Import Visualizer Script")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showImportSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        do {
                            let name = importName.trimmingCharacters(in: .whitespaces)
                            let ref = try LuaVisualizerEngine.importScript(source: importText, suggestedName: name.isEmpty ? "custom_visualizer" : name)
                            userScripts = LuaVisualizerEngine.userScripts()
                            showImportSheet = false
                            ToastCenter.shared.show("Imported \u{201C}\(ref.displayName)\u{201D}", category: .success, icon: "square.and.arrow.down")
                        } catch {
                            ToastCenter.shared.show("Couldn't import script: \(error.localizedDescription)", category: .error, icon: "exclamationmark.triangle.fill")
                        }
                    }
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
