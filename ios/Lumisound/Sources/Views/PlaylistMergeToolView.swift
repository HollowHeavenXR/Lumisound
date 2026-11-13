import SwiftUI

/// Compares two playlists — what's in both, and what's unique to each —
/// and lets you save any of the three resulting sets as a new playlist.
/// Pure client-side library-management tool, no server involvement beyond
/// whatever `LibraryManager.createPlaylist` already does for any new
/// playlist.
struct PlaylistMergeToolView: View {
    @EnvironmentObject private var library: LibraryManager

    @State private var playlistAID: UUID?
    @State private var playlistBID: UUID?

    private var playlistA: Playlist? {
        playlistAID.flatMap { id in library.playlists.first { $0.id == id } }
    }

    private var playlistB: Playlist? {
        playlistBID.flatMap { id in library.playlists.first { $0.id == id } }
    }

    private var inBoth: [Song.ID] {
        guard let a = playlistA, let b = playlistB else { return [] }
        let bSet = Set(b.songIDs)
        return a.songIDs.filter { bSet.contains($0) }
    }

    private var onlyInA: [Song.ID] {
        guard let a = playlistA, let b = playlistB else { return [] }
        let bSet = Set(b.songIDs)
        return a.songIDs.filter { !bSet.contains($0) }
    }

    private var onlyInB: [Song.ID] {
        guard let a = playlistA, let b = playlistB else { return [] }
        let aSet = Set(a.songIDs)
        return b.songIDs.filter { !aSet.contains($0) }
    }

    var body: some View {
        LKPage(title: "Compare Playlists", subtitle: "See what two playlists share, and save any part as a new one.",
               icon: "rectangle.2.swap", tint: .blue) {
            HStack(spacing: 10) {
                pickerCard("A", selection: $playlistAID, tint: .blue)
                pickerCard("B", selection: $playlistBID, tint: .pink)
            }
            if let playlistA, let playlistB, playlistA.id == playlistB.id {
                LKBanner(icon: "exclamationmark.circle", text: "Pick two different playlists.", tint: AppTheme.warning)
            } else if let playlistA, let playlistB {
                venn(a: playlistA, b: playlistB)
                resultCard(title: "In both", count: inBoth.count, tint: .purple, songIDs: inBoth, defaultName: "\(playlistA.name) ∩ \(playlistB.name)")
                resultCard(title: "Only in \(playlistA.name)", count: onlyInA.count, tint: .blue, songIDs: onlyInA, defaultName: "\(playlistA.name) only")
                resultCard(title: "Only in \(playlistB.name)", count: onlyInB.count, tint: .pink, songIDs: onlyInB, defaultName: "\(playlistB.name) only")
            } else {
                LKEmpty(icon: "circle.lefthalf.filled", title: "Pick two playlists", message: "Choose A and B to see the overlap.", tint: .blue)
            }
        }
    }

    private func pickerCard(_ label: String, selection: Binding<UUID?>, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(tint.gradient, in: Circle())
            LumiPicker("Playlist \(label)", selection: selection) {
                Text("Choose one").lumiOptionLabel("Choose one").tag(UUID?.none)
                ForEach(library.playlists) { playlist in
                    Text(playlist.name).lumiOptionLabel(String(describing: playlist.name)).tag(Optional(playlist.id))
                }
            }
            .tint(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(LKCardBackground(tint: tint, corner: 18))
    }

    private func venn(a: Playlist, b: Playlist) -> some View {
        HStack(spacing: -46) {
            ZStack {
                Circle().fill(Color.blue.opacity(0.35))
                Text("\(onlyInA.count)").font(.title2.bold()).offset(x: -18)
            }
            .frame(width: 130, height: 130)
            ZStack {
                Circle().fill(Color.pink.opacity(0.35))
                Text("\(onlyInB.count)").font(.title2.bold()).offset(x: 18)
            }
            .frame(width: 130, height: 130)
        }
        .overlay {
            Text("\(inBoth.count)")
                .font(.title3.bold())
                .padding(8)
                .background(.ultraThinMaterial, in: Circle())
        }
        .foregroundStyle(AppTheme.textPrimary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(LKCardBackground())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(inBoth.count) in both, \(onlyInA.count) only in \(a.name), \(onlyInB.count) only in \(b.name)")
    }

    private func resultCard(title: String, count: Int, tint: Color, songIDs: [Song.ID], defaultName: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(tint).frame(width: 10, height: 10)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                Spacer()
                LKPill(text: "\(count) track\(count == 1 ? "" : "s")", tint: tint)
            }
            if songIDs.isEmpty {
                Text("Nothing here.").font(.caption).foregroundStyle(AppTheme.textSecondary)
            } else {
                SaveAsPlaylistRow(songIDs: songIDs, defaultName: defaultName)
            }
        }
        .padding(14)
        .background(LKCardBackground())
    }
}

/// A "Save as New Playlist" row with an inline name field — shared by all
/// three result sections above.
private struct SaveAsPlaylistRow: View {
    let songIDs: [Song.ID]
    let defaultName: String

    @EnvironmentObject private var library: LibraryManager
    @State private var name: String = ""
    @State private var saved = false

    var body: some View {
        HStack(spacing: 10) {
            TextField("Playlist name", text: Binding(
                get: { name.isEmpty ? defaultName : name },
                set: { name = $0 }
            ))
            .padding(10)
            .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .foregroundStyle(AppTheme.textPrimary)

            Button {
                let resolvedName = name.isEmpty ? defaultName : name
                _ = library.createPlaylist(name: resolvedName, songIDs: songIDs)
                saved = true
                ToastCenter.shared.show("Saved \"\(resolvedName)\"", category: .success, icon: "checkmark.circle.fill")
            } label: {
                Image(systemName: saved ? "checkmark.circle.fill" : "plus.circle.fill")
                    .foregroundStyle(saved ? .green : AppTheme.dynamicAccent)
            }
            .buttonStyle(.plain)
        }
    }
}
