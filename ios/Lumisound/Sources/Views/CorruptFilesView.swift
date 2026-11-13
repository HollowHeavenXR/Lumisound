import SwiftUI

// MARK: - CorruptFilesView

struct CorruptFilesView: View {

    @StateObject private var service = CorruptFileFinderService.shared
    @State private var showDeleteConfirmation = false

    // MARK: Body

    var body: some View {
        LKPage(title: "Corrupt Files", subtitle: "Checks every audio file in Documents can actually be read.",
               icon: "exclamationmark.triangle.fill", tint: .orange) {
            // Scanner card.
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(service.corruptFiles.count)")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(service.corruptFiles.isEmpty ? AppTheme.success : AppTheme.warning)
                        .contentTransition(.numericText())
                    Text(service.corruptFiles.count == 1 ? "broken file" : "broken files")
                        .font(.subheadline).foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                }
                Group {
                    if let date = service.lastScanDate {
                        Text("Last scan \(date, style: .relative) ago")
                    } else {
                        Text("Never scanned")
                    }
                }
                .font(.caption).foregroundStyle(AppTheme.textSecondary)
                LKPrimaryButton(title: service.isScanning ? "Scanning…" : "Scan Now", icon: "waveform.badge.magnifyingglass", tint: .orange, busy: service.isScanning) {
                    guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
                    Task { await service.runScan(in: docs) }
                }
            }
            .padding(16)
            .background(LKCardBackground(tint: .orange))

            LKCard(footer: "Removed files go to Recently Deleted for 30 days — never a permanent delete.") {
                LKToggle(icon: "sparkles", tint: .purple, title: "Clean up automatically",
                         subtitle: "Aria moves broken files out after each scan", isOn: Binding(
                            get: { service.autoDeleteEnabled },
                            set: { service.autoDeleteEnabled = $0 }))
            }

            if !service.corruptFiles.isEmpty {
                LKSectionTitle("Flagged")
                ForEach(service.corruptFiles) { entry in corruptRow(for: entry) }
                LKPrimaryButton(title: "Delete All \(service.corruptFiles.count)", icon: "trash", tint: AppTheme.error, prominent: false) {
                    showDeleteConfirmation = true
                }
            } else if !service.isScanning && service.lastScanDate != nil {
                LKEmpty(icon: "checkmark.seal.fill", title: "Every file plays", message: "Nothing in Documents failed the integrity check.", tint: .green)
            }
        }
        .confirmationDialog(
            "Delete All Corrupt Files?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete \(service.corruptFiles.count) File\(service.corruptFiles.count == 1 ? "" : "s")", role: .destructive) {
                Task { await service.deleteCorruptFiles() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all \(service.corruptFiles.count) flagged file\(service.corruptFiles.count == 1 ? "" : "s") from your device. This action cannot be undone.")
        }
    }

    // MARK: - Corrupt Row

    private func corruptRow(for entry: CorruptFileEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            LKIcon(symbol: "waveform.slash", tint: AppTheme.warning, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.fileName).font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.textPrimary).lineLimit(2)
                Text(entry.reasonText).font(.caption).foregroundStyle(AppTheme.warning).fixedSize(horizontal: false, vertical: true)
                LKPill(text: entry.formattedSize, tint: .gray)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(LKCardBackground())
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AppTheme.bodyFont(size: 11))
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(0.8)
    }
}
