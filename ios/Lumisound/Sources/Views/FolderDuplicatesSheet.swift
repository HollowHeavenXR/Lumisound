import SwiftUI

// MARK: - FolderDuplicatesSheet
//
// Folder-scoped Duplicate Finder: the same Duplicate Engine scan, cards and
// reversible clean-up as the full-library screen, over one folder's songs.
// Its results live only here and never replace the full-library report.

struct FolderDuplicatesSheet: View {
    let songs: [Song]

    @EnvironmentObject private var library: LibraryManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = DuplicateFinderService.shared

    @State private var groups: [DupeGroup] = []
    @State private var isScanning = false
    @State private var hasScanned = false
    @State private var confirmGroup: DupeGroup?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    header
                    ForEach(groups, id: \.id) { group in
                        DupeGroupCard(group: group) { keeper in
                            let updated = dupeChooseKeeper(group: group, keeperId: keeper)
                            if let i = groups.firstIndex(where: { $0.id == group.id }) { groups[i] = updated }
                        } onCleanUp: {
                            confirmGroup = group
                        } onIgnore: {
                            dupeIgnore(songIds: group.copies.map(\.id))
                            withAnimation(LumiMotion.glide) { groups.removeAll { $0.id == group.id } }
                        }
                    }
                    if hasScanned && !isScanning && groups.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 38))
                                .foregroundStyle(AppTheme.success)
                            Text("No duplicates in this folder")
                                .font(AppTheme.headlineFont(size: 15))
                                .foregroundStyle(AppTheme.textPrimary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(24)
                    }
                }
                .padding(16)
            }
            .background(GalleryBackgroundView().ignoresSafeArea())
            .navigationTitle("Folder Duplicates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .tint(AppTheme.dynamicAccent)
                }
            }
            .confirmationDialog("Clean Up This Group?", isPresented: Binding(get: { confirmGroup != nil }, set: { if !$0 { confirmGroup = nil } }), titleVisibility: .visible) {
                if let g = confirmGroup {
                    Button("Move \(g.removeIds.count) Cop\(g.removeIds.count == 1 ? "y" : "ies") to Recently Deleted", role: .destructive) {
                        if library.resolveDuplicates(keeperID: g.keeperId, removeIDs: g.removeIds) != nil {
                            withAnimation(LumiMotion.glide) { groups.removeAll { $0.id == g.id } }
                        }
                        confirmGroup = nil
                    }
                    Button("Cancel", role: .cancel) { confirmGroup = nil }
                }
            } message: {
                Text("The kept copy takes over their favorites and playlist places. Undo from Duplicate Finder's Clean-up History.")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(songs.count) songs in this folder", systemImage: "folder")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                if isScanning { ProgressView().tint(AppTheme.dynamicAccent) }
            }
            Button {
                Task { await runScan() }
            } label: {
                Label(hasScanned ? "Scan Again" : "Scan This Folder", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(AppTheme.dynamicAccent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(isScanning || songs.count < 2)
            Text("Compares files, sources and the sound itself. Live, remix, sped-up and other versions are never treated as duplicates.")
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AppTheme.surface))
    }

    private func runScan() async {
        isScanning = true
        let report = await service.scanScoped(songs)
        groups = report.groups
        hasScanned = true
        isScanning = false
    }
}
