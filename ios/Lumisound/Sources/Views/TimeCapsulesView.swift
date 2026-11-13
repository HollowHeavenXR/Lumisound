import SwiftUI

/// List + creation flow for Time Capsules — see `TimeCapsuleStore`'s doc
/// comment for what these are. Locked capsules show a countdown; unlocked
/// ones open into `TimeCapsuleDetailView` to relive the songs and read the
/// note back.
struct TimeCapsulesView: View {
    @ObservedObject private var store = TimeCapsuleStore.shared
    @State private var showSealSheet = false

    var body: some View {
        LKPage(title: "Time Capsules", subtitle: "Songs sealed now, opened later.", icon: "shippingbox.fill", tint: .brown) {
            if store.capsules.isEmpty {
                LKSection {
                    EmptyStateView(
                        icon: "shippingbox",
                        title: "No Time Capsules Yet",
                        message: "Seal a set of songs and a note to your future self — it stays locked until the date you choose."
                    )
                }
            } else {
                LKSection {
                    ForEach(store.capsules) { capsule in
                        NavigationLink(destination: TimeCapsuleDetailView(capsule: capsule)) {
                            capsuleRow(capsule)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { store.delete(capsule.id) } label: { Label("Delete Capsule", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .background(GalleryBackgroundView().ignoresSafeArea())
        .navigationTitle("Time Capsules")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showSealSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showSealSheet) {
            SealTimeCapsuleView()
        }
    }

    private func capsuleRow(_ capsule: TimeCapsule) -> some View {
        HStack(spacing: 12) {
            Image(systemName: capsule.isUnlocked ? "shippingbox" : "lock.shippingbox")
                .font(.system(size: 20))
                .foregroundStyle(capsule.isUnlocked ? AppTheme.dynamicAccent : AppTheme.textSecondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(capsule.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(capsule.isUnlocked ? "\(capsule.songIDs.count) songs · unlocked" : lockedSubtitle(capsule))
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func lockedSubtitle(_ capsule: TimeCapsule) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Opens \(formatter.localizedString(for: capsule.unlockAt, relativeTo: Date()))"
    }
}

// MARK: - Seal flow

private struct SealTimeCapsuleView: View {
    @EnvironmentObject private var library: LibraryManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var message = ""
    @State private var unlockDate = Calendar.current.date(byAdding: .month, value: 6, to: Date()) ?? Date()
    @State private var source: Source = .favorites
    @State private var selectedPlaylistID: UUID?

    private enum Source: String, CaseIterable, Identifiable {
        case favorites = "Favorites"
        case playlist = "A Playlist"
        var id: String { rawValue }
    }

    private var resolvedSongIDs: [Song.ID] {
        switch source {
        case .favorites:
            return library.favoriteSongs.map(\.id)
        case .playlist:
            guard let selectedPlaylistID,
                  let playlist = library.playlists.first(where: { $0.id == selectedPlaylistID }) else { return [] }
            return playlist.songIDs
        }
    }

    var body: some View {
        NavigationStack {
            LKScroll {
                LKSection("Name & Note") {
                    TextField("Capsule name", text: $name)
                    TextField("A note to your future self (optional)", text: $message, axis: .vertical)
                        .lineLimit(3...6)
                }

                LKSection("What's Inside") {
                    Picker("Source", selection: $source) {
                        ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if source == .playlist {
                        if library.playlists.isEmpty {
                            Text("You don't have any playlists yet.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.textSecondary)
                        } else {
                            LumiPicker("Playlist", selection: $selectedPlaylistID) {
                                Text("Choose one").lumiOptionLabel("Choose one").tag(UUID?.none)
                                ForEach(library.playlists) { playlist in
                                    Text(playlist.name).lumiOptionLabel(String(describing: playlist.name)).tag(Optional(playlist.id))
                                }
                            }
                        }
                    }

                    Text("\(resolvedSongIDs.count) song\(resolvedSongIDs.count == 1 ? "" : "s") will be sealed.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                }

                LKSection("Unlock Date") {
                    DatePicker("Opens on", selection: $unlockDate, in: Date()..., displayedComponents: .date)
                }
            }
            .navigationTitle("Seal a Time Capsule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Seal") {
                        TimeCapsuleStore.shared.seal(
                            name: name, message: message,
                            songIDs: resolvedSongIDs, unlockAt: unlockDate
                        )
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || resolvedSongIDs.isEmpty)
                }
            }
        }
    }
}

// MARK: - Detail

struct TimeCapsuleDetailView: View {
    let capsule: TimeCapsule
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager

    private var songs: [Song] {
        // The library's own id index — this used to rebuild a dictionary of
        // the whole library on every render, with `uniqueKeysWithValues`,
        // which also crashes on a duplicate id.
        capsule.songIDs.compactMap { library.songsByID[$0] }
    }

    var body: some View {
        Group {
            if capsule.isUnlocked {
                unlockedContent
            } else {
                lockedContent
            }
        }
        .navigationTitle(capsule.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if capsule.isUnlocked { TimeCapsuleStore.shared.markOpened(capsule.id) }
        }
    }

    private var lockedContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shippingbox.fill")
                .font(.system(size: 48))
                .foregroundStyle(AppTheme.textSecondary)
            Text("Still Sealed")
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
            Text("This capsule opens \(capsule.unlockAt.formatted(date: .abbreviated, time: .omitted)).")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GalleryBackgroundView().ignoresSafeArea())
    }

    private var unlockedContent: some View {
        LKScroll {
            if !capsule.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                LKSection {
                    Text(capsule.message)
                        .font(.body)
                        .foregroundStyle(AppTheme.textPrimary)
                } header: {
                    Text("Sealed \(capsule.createdAt.formatted(date: .abbreviated, time: .omitted))")
                }
            }

            LKSection {
                Button {
                    player.setQueue(songs, startIndex: 0, autoplay: true)
                } label: {
                    Label("Play All", systemImage: "play.fill")
                }
                ForEach(songs, id: \.id) { song in
                    SongRow(song: song, isCurrent: false)
                }
            } header: {
                Text("\(songs.count) Songs")
            }
        }
        .background(GalleryBackgroundView().ignoresSafeArea())
    }
}
