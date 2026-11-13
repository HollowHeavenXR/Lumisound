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

    private var grade: String {
        switch healthScore {
        case 95...: return "A+"
        case 90..<95: return "A"
        case 80..<90: return "B"
        case 70..<80: return "C"
        default: return "D"
        }
    }

    /// The biggest fixable issue, for the "fix this first" card.
    private var fixFirst: (title: String, count: Int, icon: String)? {
        let candidates: [(String, Int, String)] = [
            ("Missing Metadata", missingMetadataCount, "text.badge.xmark"),
            ("Low Bitrate", lowBitrateCount, "waveform.badge.exclamationmark"),
            ("Corrupt Files", corruptFinder.corruptFiles.count, "exclamationmark.triangle"),
            ("Duplicates", duplicateFinder.groups.count, "doc.on.doc"),
        ]
        return candidates.filter { $0.1 > 0 }.max { $0.1 < $1.1 }.map { (title: $0.0, count: $0.1, icon: $0.2) }
    }

    var body: some View {
        LKPage(title: "Library Health", subtitle: nil, icon: "heart.text.square.fill", tint: .pink, showsHero: false) {
            scoreCard
            if songs.isEmpty {
                LKEmpty(icon: "checkmark.seal", title: "Nothing to check yet", message: "Add music and its health checks appear here.", tint: .green)
            } else {
                if let fix = fixFirst {
                    LKBanner(icon: fix.icon, text: "Fix first: \(fix.title) — \(fix.count) item\(fix.count == 1 ? "" : "s").", tint: AppTheme.warning)
                }
                LKSectionTitle("Files & tags")
                LKGrid {
                    NavigationLink { LibraryHealthSongListView(title: "Missing Metadata", songs: missingMetadataSongs) } label: {
                        issueTile(icon: "text.badge.xmark", title: "Missing tags", detail: "Artist, album, genre or year", count: missingMetadataCount)
                    }.buttonStyle(.plain)
                    NavigationLink { LibraryHealthSongListView(title: "Low Bitrate", songs: lowBitrateSongs) } label: {
                        issueTile(icon: "waveform.badge.exclamationmark", title: "Low bitrate", detail: "Under 128 kbps", count: lowBitrateCount)
                    }.buttonStyle(.plain)
                    NavigationLink { CorruptFilesView() } label: {
                        issueTile(icon: "exclamationmark.triangle", title: "Corrupt", detail: scanSubtitle(corruptFinder.lastScanDate, isScanning: corruptFinder.isScanning),
                                  count: corruptFinder.corruptFiles.count)
                    }.buttonStyle(.plain)
                    NavigationLink { DuplicateFilesView() } label: {
                        issueTile(icon: "doc.on.doc", title: "Duplicates", detail: scanSubtitle(duplicateFinder.lastScanDate, isScanning: duplicateFinder.isScanning),
                                  count: duplicateFinder.groups.count, scored: false)
                    }.buttonStyle(.plain)
                }
                LKSectionTitle("Listening")
                LKCard {
                    LKLink(icon: "forward.end", tint: .purple, title: "Often Skipped", subtitle: "Smart Shuffle plays these later",
                           value: "\(oftenSkippedCount)") {
                        OftenSkippedView(onChange: refreshIssueLists)
                    }
                }
                Text("Duplicates don't lower the score — they aren't broken, just extra.")
                    .font(.caption2).foregroundStyle(AppTheme.textSecondary).padding(.horizontal, 6)
            }
        }
        .onAppear(perform: refreshIssueLists)
        .onChange(of: library.allSongs) { refreshIssueLists() }
    }

    private var scoreCard: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().stroke(scoreColor.opacity(0.18), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: CGFloat(healthScore) / 100)
                    .stroke(AngularGradient(colors: [scoreColor.opacity(0.6), scoreColor], center: .center),
                            style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: -2) {
                    Text(grade).font(.system(size: 30, weight: .heavy, design: .rounded)).foregroundStyle(AppTheme.textPrimary)
                    Text("\(healthScore)/100").font(.caption2.monospacedDigit()).foregroundStyle(AppTheme.textSecondary)
                }
            }
            .frame(width: 112, height: 112)
            VStack(alignment: .leading, spacing: 6) {
                Text(healthScore >= 90 ? "In great shape" : healthScore >= 70 ? "Mostly healthy" : "Needs some care")
                    .font(.title3.bold()).foregroundStyle(AppTheme.textPrimary)
                Text("\(songs.count) song\(songs.count == 1 ? "" : "s") checked").font(.caption).foregroundStyle(AppTheme.textSecondary)
                let issues = missingMetadataCount + lowBitrateCount + corruptFinder.corruptFiles.count
                LKPill(text: issues == 0 ? "No issues" : "\(issues) issue\(issues == 1 ? "" : "s")", tint: issues == 0 ? .green : AppTheme.warning)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(LKCardBackground(tint: scoreColor))
        .animation(.easeOut(duration: 0.5), value: healthScore)
    }

    private func issueTile(icon: String, title: String, detail: String, count: Int, scored: Bool = true) -> some View {
        let share = songs.isEmpty ? 0 : min(1, Double(count) / Double(songs.count))
        let tint: Color = count == 0 ? .green : (scored ? AppTheme.warning : .purple)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                LKIcon(symbol: count == 0 ? "checkmark" : icon, tint: tint, size: 32)
                Spacer()
                Text("\(count)").font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(AppTheme.textPrimary)
            }
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.textPrimary)
            Text(detail).font(.caption2).foregroundStyle(AppTheme.textSecondary).lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.textSecondary.opacity(0.15))
                    Capsule().fill(tint).frame(width: geo.size.width * share)
                }
            }
            .frame(height: 4)
        }
        .padding(14)
        .background(LKCardBackground(corner: 18))
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
        LKPage(title: title, icon: nil, showsHero: false) {
            if songs.isEmpty {
                LKEmpty(icon: "checkmark.seal", title: "All clear", message: "No songs have this issue right now.", tint: .green)
            } else {
                // Rows straight in the page's lazy stack: these lists can be long.
                ForEach(songs, id: \.id) { song in
                    Button { player.play(song: song, in: songs) } label: {
                        SongRow(song: song, isCurrent: player.currentSong?.id == song.id)
                            .padding(.horizontal, 8)
                            .background(LKCardBackground(corner: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
