import Foundation
import SwiftUI

// MARK: - AdminDashboardView
//
// The in-app counterpart to the standalone /admin web dashboard (see
// main.py's _ADMIN_DASHBOARD_HTML) — same three endpoints
// (/admin/api/overview, /admin/api/download-jobs, /admin/api/errors), same
// data, native UI instead of a browser tab.
//
// Access control is enforced server-side (check_admin_or_operator only
// accepts the hardcoded operator account's own JWT or the separate
// ADMIN_TOKEN secret — see that function's doc comment in main.py) — no
// admin credential is embedded in this app at all. The `operatorUserID`
// check here is purely a client-side UX gate (don't even show the entry
// point / don't render a confusing "everything failed" screen for anyone
// else) — removing it would only hide a menu item, never grant access,
// since the server enforces the real boundary independently.
struct AdminDashboardView: View {
    static let operatorUserID = "ca8a4c53-5603-472e-9287-5fb879f28090"

    @EnvironmentObject private var account: AccountService
    @State private var isRefreshing = false
    @State private var actioningUserID: String? = nil
    @State private var showClearErrorsConfirm = false
    @State private var showClearJobsConfirm = false

    // Per-user storage quota editor (Section "Users" row action)
    @State private var editingQuotaForUser: AdminUser? = nil
    @State private var quotaInputGB: String = ""

    // Storage integrity check (Section "Storage Integrity")
    @State private var isCheckingIntegrity = false
    @State private var integrityReport: AdminStorageIntegrityReport? = nil
    @State private var verifyHashOnNextCheck = false

    var body: some View {
        Group {
            if account.currentUser?.id == Self.operatorUserID {
                dashboard
            } else {
                ContentUnavailableFallback()
            }
        }
        .navigationTitle("Admin")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
    }

    private var dashboard: some View {
        LKPage(title: "Admin", subtitle: "Operator tools for the Lumisound server.", icon: "server.rack", tint: .gray) {
            LKSection("Overview") {
                if let o = account.adminOverview {
                    overviewGrid(o)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
                NavigationLink(destination: AdminLogsView()) {
                    Label("Browse Audit Logs", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(LKRowLinkStyle())
            }

            LKSection("Download Jobs (last 24h)") {
                if let o = account.adminOverview {
                    ForEach(o.downloadJobs24h.sorted(by: { $0.key < $1.key }), id: \.key) { status, count in
                        HStack {
                            Text(status.capitalized)
                            Spacer()
                            Text("\(count)")
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                }
            }

            LKSection {
                if account.adminDownloadJobs.isEmpty {
                    Text("No jobs recorded.")
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    ForEach(account.adminDownloadJobs) { job in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(job.title?.isEmpty == false ? job.title! : job.sourceId)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Spacer()
                                statusPill(job.status)
                            }
                            if let err = job.errorMessage, !err.isEmpty {
                                Text(err)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .lineLimit(2)
                            }
                            Text([job.source, job.createdAt].compactMap { $0 }.joined(separator: " — "))
                                .font(.caption2)
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                }
            } header: {
                Text("Recent Download Jobs")
            } footer: {
                if !account.adminDownloadJobs.isEmpty {
                    Button("Clear Log", role: .destructive) { showClearJobsConfirm = true }
                        .font(.caption)
                }
            }

            LKSection {
                if account.adminUsers.isEmpty {
                    Text("No users found.")
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    ForEach(account.adminUsers) { user in
                        userRow(user)
                    }
                }
            } header: {
                Text("Users")
            }

            LKSection {
                if isCheckingIntegrity {
                    HStack {
                        ProgressView()
                        Text("Checking…").foregroundStyle(AppTheme.textSecondary)
                    }
                } else if let report = integrityReport {
                    integrityReportView(report)
                } else {
                    Text("Checks that every uploaded ('My Library') track's file still exists on disk — user-uploaded music has no other backup, unlike bridge-downloaded tracks, which can be re-fetched from their source.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Button {
                    Task {
                        isCheckingIntegrity = true
                        defer { isCheckingIntegrity = false }
                        integrityReport = await account.fetchStorageIntegrity(verifyHash: verifyHashOnNextCheck)
                    }
                } label: {
                    Text(integrityReport == nil ? "Check Storage Integrity" : "Check Again")
                }
                .disabled(isCheckingIntegrity)
                Toggle("Also verify file content (slower)", isOn: $verifyHashOnNextCheck)
                    .font(.caption)
            } header: {
                Text("Storage Integrity")
            }

            LKSection {
                if account.adminErrors.isEmpty {
                    Text("No errors logged.")
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    ForEach(account.adminErrors) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.category)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.dynamicAccent)
                                Spacer()
                                if let ts = entry.timestamp {
                                    Text(ts)
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.textSecondary)
                                }
                            }
                            Text(entry.message)
                                .font(.caption)
                                .lineLimit(3)
                        }
                    }
                }
            } header: {
                Text("Recent Errors")
            } footer: {
                if !account.adminErrors.isEmpty {
                    Button("Clear Log", role: .destructive) { showClearErrorsConfirm = true }
                        .font(.caption)
                }
            }
        }
        .refreshable { await refresh() }
        .confirmationDialog("Clear all error log entries?", isPresented: $showClearErrorsConfirm, titleVisibility: .visible) {
            Button("Clear Errors", role: .destructive) {
                Task { await account.clearAdminErrors() }
            }
        }
        .confirmationDialog("Clear all download job history?", isPresented: $showClearJobsConfirm, titleVisibility: .visible) {
            Button("Clear Jobs", role: .destructive) {
                Task { await account.clearAdminDownloadJobs() }
            }
        }
        .alert(
            "Storage Quota — \(editingQuotaForUser?.username ?? "")",
            isPresented: Binding(
                get: { editingQuotaForUser != nil },
                set: { if !$0 { editingQuotaForUser = nil } }
            )
        ) {
            TextField("GB (blank = server default)", text: $quotaInputGB)
                .keyboardType(.numberPad)
            Button("Save") {
                guard let user = editingQuotaForUser else { return }
                let gb = Double(quotaInputGB.trimmingCharacters(in: .whitespaces))
                let bytes = gb.map { Int($0 * 1_073_741_824) }  // GB -> bytes
                Task { await account.setAdminUserQuota(id: user.id, quotaBytes: bytes) }
                editingQuotaForUser = nil
            }
            Button("Clear Override", role: .destructive) {
                guard let user = editingQuotaForUser else { return }
                Task { await account.setAdminUserQuota(id: user.id, quotaBytes: nil) }
                editingQuotaForUser = nil
            }
            Button("Cancel", role: .cancel) { editingQuotaForUser = nil }
        } message: {
            Text("Enter a limit in GB for this user's uploaded music storage. Leave blank and tap Save (or tap Clear Override) to fall back to the server-wide default.")
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isRefreshing {
                    ProgressView()
                } else {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private func overviewGrid(_ o: AdminOverview) -> some View {
        let items: [(String, String)] = [
            ("Users", "\(o.userCount)"),
            ("Music Files", "\(o.musicFileCount)"),
            ("Storage Used", formattedBytes(o.musicBytes)),
            ("Disk Free", o.disk.map { formattedBytes(Int($0.freeBytes)) } ?? "n/a"),
            ("Errors (24h)", "\(o.recentErrorCount24h)"),
            ("yt-dlp Slots", "\(o.concurrency.ytdlpAvailable)/\(o.concurrency.ytdlpMax) free"),
            ("Transcode Slots", "\(o.concurrency.transcodeAvailable)/\(o.concurrency.transcodeMax) free"),
            ("yt-dlp Version", o.ytDlpVersion),
        ]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(items, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 2) {
                    Text(value)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(label.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .kerning(0.5)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func userRow(_ user: AdminUser) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(user.username)
                    .font(.subheadline.weight(.medium))
                if user.isOperator {
                    Text("OPERATOR")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppTheme.dynamicAccent)
                }
                Spacer()
                if !user.isActive {
                    Text("Deactivated")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
            Text([user.email, "\(user.activeSessions) active session(s)"].compactMap { $0 }.joined(separator: " — "))
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)

            HStack(spacing: 4) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 10))
                Text(quotaSummary(for: user))
            }
            .font(.caption2)
            .foregroundStyle(AppTheme.textSecondary)

            if !user.isOperator {
                HStack(spacing: 16) {
                    if actioningUserID == user.id {
                        ProgressView()
                    } else {
                        if user.isActive {
                            Button("Deactivate", role: .destructive) {
                                performUserAction(user.id) { await account.deactivateAdminUser(id: user.id) }
                            }
                        } else {
                            Button("Reactivate") {
                                performUserAction(user.id) { await account.reactivateAdminUser(id: user.id) }
                            }
                        }
                        Button("Force Logout") {
                            performUserAction(user.id) { await account.forceLogoutAdminUser(id: user.id) }
                        }
                        Button("Quota") {
                            quotaInputGB = user.storageQuotaBytes.map { String(format: "%.1f", Double($0) / 1_073_741_824) } ?? ""
                            editingQuotaForUser = user
                        }
                    }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.dynamicAccent)
            }
        }
    }

    private func performUserAction(_ userID: String, _ action: @escaping () async -> Bool) {
        actioningUserID = userID
        Task {
            _ = await action()
            await account.fetchAdminUsers()
            actioningUserID = nil
        }
    }

    private func statusPill(_ status: String) -> some View {
        let color: Color = status == "completed" ? .green : (status == "failed" || status == "error" ? .red : AppTheme.textSecondary)
        return Text(status.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func formattedBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func quotaSummary(for user: AdminUser) -> String {
        let used = formattedBytes(user.storageUsedBytes ?? 0)
        guard let quota = user.storageQuotaBytes, quota > 0 else {
            return "\(used) used — server default limit"
        }
        return "\(used) / \(formattedBytes(quota)) used"
    }

    @ViewBuilder
    private func integrityReportView(_ report: AdminStorageIntegrityReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(report.checked)/\(report.totalRows) file(s) checked" + (report.hashVerified ? " (content verified)" : " (existence only)"))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)

            if report.missing.isEmpty && report.corrupted.isEmpty {
                Label("No issues found", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                if !report.missing.isEmpty {
                    Label("\(report.missing.count) file(s) missing from disk", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    ForEach(report.missing) { issue in
                        Text(issue.filename)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                if !report.corrupted.isEmpty {
                    Label("\(report.corrupted.count) file(s) with mismatched content", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    ForEach(report.corrupted) { issue in
                        Text(issue.filename)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
            }
        }
    }

    private func refresh() async {
        guard account.currentUser?.id == Self.operatorUserID else { return }
        isRefreshing = true
        async let overview: () = account.fetchAdminOverview()
        async let jobs: () = account.fetchAdminDownloadJobs()
        async let errors: () = account.fetchAdminErrors()
        async let users: () = account.fetchAdminUsers()
        _ = await (overview, jobs, errors, users)
        isRefreshing = false
    }
}

private struct ContentUnavailableFallback: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 32))
                .foregroundStyle(AppTheme.textSecondary)
            Text("Not Available")
                .font(.headline)
            Text("This screen is only available to the app's operator account.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
