import SwiftUI

/// Songs you tend to skip early, as Smart Shuffle sees them (skip history
/// lives in the Rust core and syncs across your devices). Skips fade over
/// a couple of months on their own; forgetting a song here puts it back on
/// equal footing right away.
struct OftenSkippedView: View {
    /// Called after a reset so the Library Health count refreshes.
    var onChange: () -> Void = {}

    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager
    @State private var rows: [Row] = []
    @State private var confirmResetAll = false

    struct Row: Identifiable {
        let song: Song
        let record: SkipRecord
        var id: String { song.id }
    }

    /// Faded skip weight from which Smart Shuffle starts playing a song later
    /// (matches `weight` in rust/core/src/shuffle.rs).
    static let shuffleThreshold = 1.5

    /// Library songs Smart Shuffle currently holds back, most-skipped first.
    static func entries(in songs: [Song]) -> [Row] {
        let top = skipTop(limit: 500).filter { $0.weight >= shuffleThreshold }
        guard !top.isEmpty else { return [] }
        let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return top.compactMap { r in byID[r.songId].map { Row(song: $0, record: r) } }
    }

    private func reload() {
        rows = Self.entries(in: library.allSongs)
    }

    private func subtitle(_ r: SkipRecord) -> String {
        var parts = ["Skipped \(r.skips)×"]
        if r.plays > 0 { parts.append("played \(r.plays)×") }
        if let last = r.lastSkippedAt {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .short
            parts.append(f.localizedString(for: Date(timeIntervalSince1970: last), relativeTo: Date()))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        List {
            if rows.isEmpty {
                EmptyStateView(
                    icon: "forward.end",
                    title: "Nothing Held Back",
                    message: "Songs you skip in the first few seconds show up here, and Smart Shuffle plays them later. Skips fade on their own after a while."
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(rows) { row in
                        Button {
                            player.play(song: row.song, in: rows.map(\.song), uiSource: "often_skipped")
                        } label: {
                            SongRow(song: row.song, isCurrent: player.currentSong?.id == row.song.id,
                                    subtitle: subtitle(row.record))
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                skipClear(songId: row.song.id)
                                reload()
                                onChange()
                            } label: {
                                Label("Forget", systemImage: "arrow.uturn.backward")
                            }
                            .tint(AppTheme.dynamicAccent)
                        }
                    }
                    .listRowBackground(AppTheme.surface.opacity(0.5))
                } footer: {
                    Text("Swipe a song to forget its skips. Skips you make here sync to your other devices when you're signed in.")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(GalleryBackgroundView().ignoresSafeArea())
        .navigationTitle("Often Skipped")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !rows.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reset All") { confirmResetAll = true }
                }
            }
        }
        .confirmationDialog("Forget all skips?", isPresented: $confirmResetAll, titleVisibility: .visible) {
            Button("Forget All Skips", role: .destructive) {
                skipClearAll()
                reload()
                onChange()
            }
        } message: {
            Text("Smart Shuffle will treat every song equally again.")
        }
        .onAppear(perform: reload)
    }
}
