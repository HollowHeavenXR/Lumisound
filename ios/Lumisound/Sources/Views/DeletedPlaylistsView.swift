import SwiftUI

/// A 30-day recovery list for deleted playlists — see
/// `DeletedPlaylistsStore`'s doc comment. Same "swipe to restore or delete
/// forever" shape as the Downloads Manager's Recently Deleted screen.
struct DeletedPlaylistsView: View {
    @EnvironmentObject private var library: LibraryManager
    @ObservedObject private var store = DeletedPlaylistsStore.shared

    var body: some View {
        LKPage(title: "Recently Deleted", subtitle: "Playlists wait here 30 days before they're gone for good.",
               icon: "trash.fill", tint: .red) {
            if store.entries.isEmpty {
                LKEmpty(icon: "checkmark.circle", title: "Nothing deleted", message: "Deleted playlists show up here for 30 days.", tint: .green)
            } else {
                ForEach(store.entries) { entry in entryCard(entry) }
                Button(role: .destructive) { store.purgeAll() } label: {
                    Label("Delete all forever", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(AppTheme.error)
                        .background(AppTheme.error.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.entries.map(\.id))
    }

    /// Days left before the 30-day purge, as a draining ring.
    private func entryCard(_ entry: DeletedPlaylistEntry) -> some View {
        let elapsed = Date().timeIntervalSince(entry.deletedAt) / 86_400
        let left = max(0, 30 - Int(elapsed.rounded(.down)))
        return HStack(spacing: 14) {
            ZStack {
                Circle().stroke(AppTheme.textSecondary.opacity(0.15), lineWidth: 4)
                Circle().trim(from: 0, to: Double(left) / 30)
                    .stroke(left <= 3 ? AppTheme.error : Color.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: -2) {
                    Text("\(left)").font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("days").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(AppTheme.textPrimary)
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.playlist.name).font(.headline).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                Text("\(entry.playlist.songCount) song\(entry.playlist.songCount == 1 ? "" : "s") · deleted \(relativeDate(entry.deletedAt))")
                    .font(.caption).foregroundStyle(AppTheme.textSecondary)
            }
            Spacer(minLength: 6)
            Button { restore(entry) } label: {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 14, weight: .bold))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(.white)
                    .background(AppTheme.dynamicAccent.gradient, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Restore \(entry.playlist.name)")
            Menu {
                Button { restore(entry) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                Button(role: .destructive) { store.purge(entryID: entry.id) } label: { Label("Delete Forever", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .bold))
                    .frame(width: 32, height: 36)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(14)
        .background(LKCardBackground())
    }

    private func restore(_ entry: DeletedPlaylistEntry) {
        guard let playlist = store.restore(entryID: entry.id) else { return }
        library.restorePlaylist(playlist)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
