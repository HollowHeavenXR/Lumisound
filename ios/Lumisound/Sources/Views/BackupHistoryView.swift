import SwiftUI

// MARK: - BackupHistoryView
//
// Shows the automatic server-side sync backups for this account (taken
// before every push and before every restore — see `ios_user_backups` and
// GET/POST /user/backups... on the bridge). Lets the user roll back to a
// previous snapshot of their favorites/playlists/settings if a bad sync
// ever overwrites their data.

struct BackupHistoryView: View {
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager

    @State private var isLoading = false
    @State private var pendingRestore: SyncBackup?
    @State private var showClearAllConfirm = false

    /// Backups grouped by calendar day, newest first.
    private var days: [(day: String, items: [SyncBackup])] {
        var order: [String] = []
        var map: [String: [SyncBackup]] = [:]
        for b in account.backups {
            let key = b.date.map { $0.formatted(date: .complete, time: .omitted) } ?? "Earlier"
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(b)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    var body: some View {
        LKPage(title: "Backup History", subtitle: "A snapshot is saved before every sync and every restore.",
               icon: "clock.arrow.circlepath", tint: .blue) {
            if isLoading && account.backups.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(30)
            } else if account.backups.isEmpty {
                LKEmpty(icon: "clock.badge.questionmark", title: "No backups yet", message: "One is taken automatically each time your library syncs.", tint: .blue)
            } else {
                LKBanner(icon: "arrow.uturn.backward.circle", text: "Restoring replaces favorites, playlists and synced settings with that snapshot. Your current state is backed up first, so a restore can be undone.", tint: .blue)
                ForEach(days, id: \.day) { day in
                    LKSectionTitle(day.day)
                    VStack(spacing: 0) {
                        ForEach(Array(day.items.enumerated()), id: \.element.id) { i, backup in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(spacing: 0) {
                                    Circle().fill(Color.blue).frame(width: 10, height: 10).padding(.top, 5)
                                    if i < day.items.count - 1 {
                                        Rectangle().fill(Color.blue.opacity(0.3)).frame(width: 2).frame(maxHeight: .infinity)
                                    }
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(backup.date.map { $0.formatted(date: .omitted, time: .shortened) } ?? backup.createdAt)
                                        .font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.textPrimary)
                                    Text(backup.reasonDisplayName).font(.caption).foregroundStyle(AppTheme.textSecondary)
                                    HStack(spacing: 6) {
                                        LKPill(text: "\(backup.favoriteCount) favorites", tint: .pink)
                                        LKPill(text: "\(backup.playlistCount) playlists", tint: .blue)
                                    }
                                }
                                .padding(.bottom, 14)
                                Spacer()
                                Button { pendingRestore = backup } label: {
                                    Text("Restore")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .foregroundStyle(.blue)
                                        .background(Color.blue.opacity(0.14), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .disabled(account.isSyncing)
                            }
                        }
                    }
                    .padding(14)
                    .background(LKCardBackground())
                }
                LKCard(footer: "Deletes every snapshot. Your current favorites, playlists and settings stay as they are.") {
                    LKButtonRow(icon: "trash", title: "Clear All Backups", destructive: true, busy: account.isSyncing) { showClearAllConfirm = true }
                }
            }
        }
        .task {
            isLoading = true
            await account.fetchBackups()
            isLoading = false
        }
        .refreshable {
            await account.fetchBackups()
        }
        .confirmationDialog(
            "Restore this backup?",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                guard let backup = pendingRestore else { return }
                pendingRestore = nil
                Task { await account.restoreBackup(id: backup.id, library: library, player: player) }
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            if let backup = pendingRestore, let date = backup.date {
                Text("This replaces your current favorites, playlists, and synced settings with the snapshot from \(date.formatted(.relative(presentation: .named))).")
            } else {
                Text("This replaces your current favorites, playlists, and synced settings with this snapshot.")
            }
        }
        .confirmationDialog(
            "Clear all backups?",
            isPresented: $showClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                Task { await account.clearBackups() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all \(account.backups.count) backup snapshot\(account.backups.count == 1 ? "" : "s"). This cannot be undone.")
        }
    }
}
