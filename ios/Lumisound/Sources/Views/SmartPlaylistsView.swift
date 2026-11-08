import SwiftUI

// MARK: - SmartPlaylistsView (list)

struct SmartPlaylistsView: View {
    @ObservedObject private var store = SmartPlaylistStore.shared
    @State private var editing: SmartPlaylist?
    @State private var creatingNew = false

    var body: some View {
        List {
            if store.playlists.isEmpty {
                EmptyStateView(
                    icon: "sparkles",
                    title: "No smart playlists",
                    message: "Smart playlists fill themselves from rules — like \"Favorites\", \"120–135 BPM\", or \"downloaded from YouTube\" — and stay up to date automatically."
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(store.playlists) { pl in
                    NavigationLink {
                        SmartPlaylistDetailView(playlistID: pl.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: pl.icon)
                                .font(.system(size: 18))
                                .foregroundStyle(AppTheme.dynamicAccent)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pl.name)
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .lineLimit(1)
                                Text(ruleSummary(pl))
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            store.remove(id: pl.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            editing = pl
                        } label: {
                            Label("Edit", systemImage: "slider.horizontal.3")
                        }
                        .tint(AppTheme.dynamicAccent)
                    }
                }
            }
        }
        // `.plain`, not `.insetGrouped` — see FavoritesView's identical fix;
        // `.insetGrouped` splits each Section into a separate floating card
        // with the gallery background showing fully through the gaps.
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(GalleryBackgroundView().ignoresSafeArea())
        .navigationTitle("Smart Playlists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    creatingNew = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $editing) { pl in
            SmartPlaylistEditorView(playlist: pl) { store.update($0) }
        }
        .sheet(isPresented: $creatingNew) {
            SmartPlaylistEditorView(playlist: SmartPlaylist(rules: [SmartRule()])) { store.add($0) }
        }
    }

    private func ruleSummary(_ pl: SmartPlaylist) -> String {
        if pl.rules.isEmpty { return "All songs" }
        let connector = pl.match == .all ? " AND " : " OR "
        return pl.rules.map { "\($0.field.label) \($0.op.label)" }.joined(separator: connector)
    }
}

// MARK: - SmartPlaylistEditorView

struct SmartPlaylistEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SmartPlaylist
    private let onSave: (SmartPlaylist) -> Void

    private static let icons = ["sparkles", "bolt.fill", "flame.fill", "heart.fill",
                                "moon.fill", "figure.run", "guitars.fill", "star.fill"]

    init(playlist: SmartPlaylist, onSave: @escaping (SmartPlaylist) -> Void) {
        _draft = State(initialValue: playlist)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Smart playlist name", text: $draft.name)
                    LumiPicker("Icon", selection: $draft.icon) {
                        ForEach(Self.icons, id: \.self) { icon in
                            Image(systemName: icon).tag(icon)
                        }
                    }
                }

                Section("Matching") {
                    Picker("Match", selection: $draft.match) {
                        ForEach(SmartMatch.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Rules") {
                    ForEach(draft.rules.indices, id: \.self) { i in
                        ruleEditor(i)
                    }
                    .onDelete { draft.rules.remove(atOffsets: $0) }

                    Button {
                        draft.rules.append(SmartRule())
                    } label: {
                        Label("Add Rule", systemImage: "plus.circle")
                    }
                }

                Section("Order & Limit") {
                    LumiPicker("Sort by", selection: $draft.sort) {
                        ForEach(SmartSort.allCases) { Text($0.label).lumiOptionLabel(String(describing: $0.label)).tag($0) }
                    }
                    Stepper(draft.limit == 0 ? "Limit: Unlimited" : "Limit: \(draft.limit)",
                            value: $draft.limit, in: 0...1000, step: 10)
                }

                Section {
                    TextEditor(text: Binding(
                        get: { draft.luaScript ?? "" },
                        set: { draft.luaScript = $0.isEmpty ? nil : $0 }
                    ))
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 140)

                    Button {
                        draft.luaScript = Self.exampleLuaScript
                    } label: {
                        Label("Insert Example", systemImage: "wand.and.stars")
                    }
                } header: {
                    Text("Advanced: Lua Rule (optional)")
                } footer: {
                    Text("Applied ON TOP OF the rules above. Define `function matches(song) ... end` — `song` carries title, artist, album, genre, year, duration, bpm, favorite, source, play_count, days_since_played, days_since_added.")
                }
            }
            .navigationTitle("Smart Playlist")
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

    private static let exampleLuaScript = """
    function matches(song)
        -- Workout mix: upbeat and not something already on heavy rotation.
        return song.bpm ~= nil and song.bpm >= 120
            and song.play_count < 20
    end
    """

    @ViewBuilder
    private func ruleEditor(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LumiPicker("Field", selection: $draft.rules[i].field) {
                ForEach(SmartField.allCases) { Text($0.label).lumiOptionLabel(String(describing: $0.label)).tag($0) }
            }
            .onChange(of: draft.rules[i].field) { newField in
                // Reset the operator to one valid for the new field kind.
                let valid = SmartOp.available(for: newField.kind)
                if !valid.contains(draft.rules[i].op) {
                    draft.rules[i].op = valid.first ?? .contains
                }
            }

            LumiPicker("Condition", selection: $draft.rules[i].op) {
                ForEach(SmartOp.available(for: draft.rules[i].field.kind)) { Text($0.label).lumiOptionLabel(String(describing: $0.label)).tag($0) }
            }

            valueEditor(i)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func valueEditor(_ i: Int) -> some View {
        switch draft.rules[i].field.kind {
        case .text:
            TextField("Value", text: $draft.rules[i].text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .number:
            HStack {
                TextField("Value", value: $draft.rules[i].number, format: .number)
                    .keyboardType(.decimalPad)
                if draft.rules[i].op == .between {
                    Text("to").foregroundStyle(AppTheme.textSecondary)
                    TextField("Upper", value: $draft.rules[i].number2, format: .number)
                        .keyboardType(.decimalPad)
                }
            }
        case .boolean:
            EmptyView()
        case .source:
            LumiPicker("Source", selection: $draft.rules[i].source) {
                ForEach(SmartSource.allCases) { Text($0.label).lumiOptionLabel(String(describing: $0.label)).tag($0) }
            }
        }
    }
}

// MARK: - SmartPlaylistDetailView

struct SmartPlaylistDetailView: View {
    let playlistID: String

    @ObservedObject private var store = SmartPlaylistStore.shared
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager
    @State private var showEditor = false

    private var playlist: SmartPlaylist? { store.playlists.first { $0.id == playlistID } }

    /// Evaluated once per change of the library, favourites or rules (see
    /// `.task(id:)`/`.onChange` below). It was a computed property read
    /// about six times a render — each read ran every rule over the whole
    /// library and sorted the result, and this view re-renders on every
    /// player change.
    @State private var matched: [Song] = []

    private func evaluateMatched() -> [Song] {
        guard let playlist else { return [] }
        return playlist.evaluate(over: library.allSongs, favorites: library.favoriteSongIDs)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Button {
                        if let first = matched.first { player.play(song: first, in: matched) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.dynamicAccent)
                    .disabled(matched.isEmpty)

                    Button {
                        let shuffled = matched.smartShuffled()
                        if let first = shuffled.first { player.play(song: first, in: shuffled) }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(AppTheme.dynamicAccent)
                    .disabled(matched.isEmpty)
                }
                .listRowBackground(Color.clear)
            } header: {
                Text("\(matched.count) SONG\(matched.count == 1 ? "" : "S") · UPDATES AUTOMATICALLY")
                    .font(AppTheme.bodyFont(size: 11))
                    .foregroundStyle(AppTheme.textSecondary)
                    .kerning(0.8)
            }

            if matched.isEmpty {
                EmptyStateView(icon: "sparkles", title: "No matches yet",
                               message: "No songs in your library match these rules right now.")
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(matched) { song in
                        Button {
                            player.play(song: song, in: matched)
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkThumbnail(song: song, size: 44)
                                    .environmentObject(library)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.displayName)
                                        .foregroundStyle(AppTheme.textPrimary)
                                        .lineLimit(1)
                                    Text(song.artist.isEmpty ? "Unknown Artist" : song.artist)
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowBackground(AppTheme.surface.opacity(0.5))
            }
        }
        // `.plain`, not `.insetGrouped` — see FavoritesView's identical fix;
        // `.insetGrouped` splits each Section into a separate floating card
        // with the gallery background showing fully through the gaps.
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(GalleryBackgroundView().ignoresSafeArea())
        .onAppear { matched = evaluateMatched() }
        .onChange(of: library.allSongs) { matched = evaluateMatched() }
        .onChange(of: library.favoriteSongIDs) { matched = evaluateMatched() }
        .onChange(of: playlist) { matched = evaluateMatched() }
        .navigationTitle(playlist?.name ?? "Smart Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showEditor = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .disabled(playlist == nil)
            }
        }
        .sheet(isPresented: $showEditor) {
            if let playlist {
                SmartPlaylistEditorView(playlist: playlist) { store.update($0) }
            }
        }
    }
}
