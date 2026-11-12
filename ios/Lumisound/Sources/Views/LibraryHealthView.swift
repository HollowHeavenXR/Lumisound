import SwiftUI

/// A unified scorecard tying together library-quality signals that
/// otherwise live as separate, easy-to-forget-about tools — Duplicate
/// Finder and Corrupt File Finder each already track their own state
/// (`DuplicateFinderService`/`CorruptFileFinderService`, read here rather
/// than duplicated), plus two new checks computed directly from
/// `LibraryManager.allSongs` that nothing else in the app currently
/// surfaces: missing metadata and low-bitrate files. One screen answering
/// "how healthy is my library, and what should I fix first" instead of
/// three unrelated tools a user has to remember to open individually.
struct LibraryHealthView: View {
    @EnvironmentObject private var library: LibraryManager
    @ObservedObject private var corruptFinder = CorruptFileFinderService.shared
    @ObservedObject private var duplicateFinder = DuplicateFinderService.shared

    private var songs: [Song] { library.allSongs }

    /// Filtered once per library change (see `.task(id:)`), not on every
    /// read — the score, rows and destinations read these several times a
    /// render, and the corrupt-file scan re-renders this view as it runs.
    @State private var missingMetadataSongs: [Song] = []
    @State private var lowBitrateSongs: [Song] = []
    /// Songs Smart Shuffle currently plays later because of early skips.
    @State private var oftenSkippedCount = 0

    private var missingMetadataCount: Int { missingMetadataSongs.count }
    private var lowBitrateCount: Int { lowBitrateSongs.count }

    private func refreshIssueLists() {
        let all = songs
        missingMetadataSongs = all.filter { $0.artist.isEmpty || $0.album.isEmpty || $0.genre.isEmpty || $0.year.isEmpty }
        lowBitrateSongs = all.filter { $0.bitrate > 0 && $0.bitrate < 128 }
        oftenSkippedCount = OftenSkippedView.entries(in: all).count
    }

    /// 100 minus the percentage of the library affected by a missing-
    /// metadata, low-bitrate, or corrupt-file issue. Duplicates are shown
    /// but deliberately excluded from the score — a duplicate isn't a
    /// defect in either individual file, just a housekeeping opportunity.
    private var healthScore: Int {
        guard !songs.isEmpty else { return 100 }
        let issues = missingMetadataCount + lowBitrateCount + corruptFinder.corruptFiles.count
        let ratio = min(1.0, Double(issues) / Double(songs.count))
        return max(0, 100 - Int((ratio * 100).rounded()))
    }

    private var scoreColor: Color {
        switch healthScore {
        case 90...: return .green
        case 70..<90: return AppTheme.dynamicAccent
        default: return AppTheme.warning
        }
    }

    var body: some View {
        List {
            Section {
                scoreCard
            }
            .listRowBackground(Color.clear)
            .listSectionSeparator(.hidden)

            if songs.isEmpty {
                Section {
                    EmptyStateView(
                        icon: "checkmark.seal",
                        title: "Nothing to Check Yet",
                        message: "Add some music to your library and its health checks will show up here."
                    )
                }
                .listRowBackground(Color.clear)
            } else {
                Section("Metadata") {
                    NavigationLink(destination: LibraryHealthSongListView(
                        title: "Missing Metadata",
                        songs: missingMetadataSongs
                    )) {
                        healthRow(
                            icon: "text.badge.xmark",
                            title: "Missing Metadata",
                            subtitle: "Artist, album, genre, or year",
                            count: missingMetadataCount
                        )
                    }
                    NavigationLink(destination: LibraryHealthSongListView(
                        title: "Low Bitrate",
                        songs: lowBitrateSongs
                    )) {
                        healthRow(
                            icon: "waveform.badge.exclamationmark",
                            title: "Low Bitrate",
                            subtitle: "Under 128 kbps",
                            count: lowBitrateCount
                        )
                    }
                }
                .listRowBackground(tintedRowBackground(.pink))

                Section {
                    NavigationLink(destination: DuplicateFilesView()) {
                        healthRow(
                            icon: "doc.on.doc",
                            title: "Duplicates",
                            subtitle: scanSubtitle(duplicateFinder.lastScanDate, isScanning: duplicateFinder.isScanning),
                            count: duplicateFinder.groups.count
                        )
                    }
                    NavigationLink(destination: CorruptFilesView()) {
                        healthRow(
                            icon: "exclamationmark.triangle",
                            title: "Corrupt Files",
                            subtitle: scanSubtitle(corruptFinder.lastScanDate, isScanning: corruptFinder.isScanning),
                            count: corruptFinder.corruptFiles.count
                        )
                    }
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("These two run on demand — open either one and tap Scan Now for an up-to-date count.")
                }
                .listRowBackground(tintedRowBackground(.pink))

                Section {
                    NavigationLink(destination: OftenSkippedView(onChange: refreshIssueLists)) {
                        healthRow(
                            icon: "forward.end",
                            title: "Often Skipped",
                            subtitle: "Played later by Smart Shuffle",
                            count: oftenSkippedCount
                        )
                    }
                } header: {
                    Text("Listening")
                }
                .listRowBackground(tintedRowBackground(.pink))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(GalleryBackgroundView().ignoresSafeArea())
        // `onChange(of: allSongs)`, not a count — fixing a song's metadata
        // keeps the count but should drop it from the list. The comparison
        // is a buffer-identity check unless the library really changed.
        .onAppear(perform: refreshIssueLists)
        .onChange(of: library.allSongs) { refreshIssueLists() }
        .navigationTitle("Library Health")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var scoreCard: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(AppTheme.elevatedSurface, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: CGFloat(healthScore) / 100)
                    .stroke(scoreColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(healthScore)")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .frame(width: 120, height: 120)
            .padding(.top, 8)

            Text("\(songs.count) song\(songs.count == 1 ? "" : "s") in your library")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func healthRow(icon: String, title: String, subtitle: String, count: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(count > 0 ? AppTheme.warning : AppTheme.textSecondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            Text("\(count)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(count > 0 ? AppTheme.warning : AppTheme.textSecondary)
        }
        .padding(.vertical, 2)
    }

    private func scanSubtitle(_ lastScan: Date?, isScanning: Bool) -> String {
        if isScanning { return "Scanning…" }
        guard let lastScan else { return "Not scanned yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Scanned \(formatter.localizedString(for: lastScan, relativeTo: Date()))"
    }
}

/// Plain list of songs flagged by one of `LibraryHealthView`'s metadata
/// checks — tap to jump straight to that song.
private struct LibraryHealthSongListView: View {
    let title: String
    let songs: [Song]

    @EnvironmentObject private var player: AudioPlayerManager

    var body: some View {
        List {
            if songs.isEmpty {
                EmptyStateView(icon: "checkmark.seal", title: "All Clear", message: "No songs currently have this issue.")
                    .listRowBackground(Color.clear)
            } else {
                ForEach(songs, id: \.id) { song in
                    Button {
                        player.play(song: song, in: songs)
                    } label: {
                        SongRow(song: song, isCurrent: player.currentSong?.id == song.id)
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(AppTheme.surface.opacity(0.5))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(GalleryBackgroundView().ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
