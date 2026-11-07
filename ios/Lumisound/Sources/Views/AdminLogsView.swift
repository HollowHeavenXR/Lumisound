import SwiftUI

// MARK: - AdminLogsView
//
// General-purpose audit log browser — GET /admin/api/logs, every level/
// category the client's AppLogger has ever uploaded, not just the
// level='error' rows AdminDashboardView's "Recent Errors" section shows.
// Reachable only from AdminDashboardView (same operator-only gate).
struct AdminLogsView: View {
    @EnvironmentObject private var account: AccountService

    @State private var logs: [AdminLogEntry] = []
    @State private var isLoading = false
    @State private var levelFilter: String = "all"
    @State private var categoryFilter: String = ""
    @State private var searchText: String = ""

    private static let levels = ["all", "debug", "info", "warning", "error"]

    var body: some View {
        List {
            Section {
                LumiPicker("Level", selection: $levelFilter) {
                    ForEach(Self.levels, id: \.self) { level in
                        Text(level.capitalized).lumiOptionLabel(String(describing: level.capitalized)).tag(level)
                    }
                }
                TextField("Category (e.g. account, admin, network)", text: $categoryFilter)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Search message text", text: $searchText)
                    .autocorrectionDisabled()
                Button {
                    Task { await runQuery() }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("Search")
                    }
                }
                .disabled(isLoading)
            } header: {
                Text("Filters")
            }

            Section {
                if logs.isEmpty {
                    Text(isLoading ? "Loading…" : "No matching log entries.")
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    ForEach(logs) { entry in
                        logRow(entry)
                    }
                    if logs.count >= 100 {
                        Button("Load Older") {
                            Task { await runQuery(before: logs.last?.timestamp) }
                        }
                        .disabled(isLoading)
                    }
                }
            } header: {
                Text("Results (\(logs.count))")
            }
        }
        .navigationTitle("Audit Logs")
        .navigationBarTitleDisplayMode(.inline)
        .task { await runQuery() }
    }

    private func logRow(_ entry: AdminLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(entry.category)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.dynamicAccent)
                levelBadge(entry.level)
                Spacer()
                if let ts = entry.timestamp {
                    Text(ts)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            Text(entry.message)
                .font(.caption)
                .lineLimit(4)
            HStack(spacing: 6) {
                if let userId = entry.userId {
                    Text("user: \(userId.prefix(8))")
                }
                if let device = entry.deviceModel {
                    Text(device)
                }
                if let appVersion = entry.appVersion {
                    Text("v\(appVersion)")
                }
            }
            .font(.caption2)
            .foregroundStyle(AppTheme.textSecondary.opacity(0.8))
        }
        .padding(.vertical, 2)
    }

    private func levelBadge(_ level: String) -> some View {
        let color: Color = level == "error" ? .red : (level == "warning" ? .orange : AppTheme.textSecondary)
        return Text(level.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func runQuery(before: String? = nil) async {
        isLoading = true
        defer { isLoading = false }
        let page = await account.fetchAdminLogs(
            level: levelFilter == "all" ? nil : levelFilter,
            category: categoryFilter.trimmingCharacters(in: .whitespaces).isEmpty ? nil : categoryFilter,
            search: searchText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : searchText,
            before: before
        )
        if before != nil {
            logs.append(contentsOf: page)
        } else {
            logs = page
        }
    }
}
