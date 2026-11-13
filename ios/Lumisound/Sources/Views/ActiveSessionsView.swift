import SwiftUI

// MARK: - ActiveSessionsView
//
// Shows every active login (device/session) for this account, from
// GET /auth/sessions, and lets the user sign out individual devices via
// DELETE /auth/sessions/{token_id}.

struct ActiveSessionsView: View {
    @EnvironmentObject private var account: AccountService

    @State private var pendingRevoke: AccountSession?

    private func deviceIcon(_ name: String?) -> String {
        let n = (name ?? "").lowercased()
        if n.contains("ipad") { return "ipad" }
        if n.contains("tv") { return "appletv" }
        if n.contains("watch") { return "applewatch" }
        if n.contains("mac") || n.contains("web") || n.contains("browser") { return "laptopcomputer" }
        return "iphone"
    }

    private func sessionCard(_ session: AccountSession) -> some View {
        HStack(spacing: 14) {
            Image(systemName: deviceIcon(session.deviceName))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(session.isCurrent ? .white : Color.blue)
                .frame(width: 46, height: 46)
                .background(session.isCurrent ? AnyShapeStyle(Color.blue.gradient) : AnyShapeStyle(Color.blue.opacity(0.14)),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.deviceName ?? "Unknown device").font(.headline).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                    if session.isCurrent { LKPill(text: "You", tint: .blue) }
                }
                if let date = session.createdDate {
                    Text("Signed in \(date.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(AppTheme.textSecondary)
                }
            }
            Spacer(minLength: 4)
            Button { pendingRevoke = session } label: {
                Text("Sign out")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .foregroundStyle(AppTheme.error)
                    .background(AppTheme.error.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(account.isSyncing)
        }
        .padding(14)
        .background(LKCardBackground(tint: session.isCurrent ? .blue : nil))
    }

    var body: some View {
        LKPage(title: "Active Sessions", subtitle: "Every device signed in to your Lumisound account.",
               icon: "laptopcomputer.and.iphone", tint: .blue) {
            if account.sessions.isEmpty {
                LKEmpty(icon: "iphone.slash", title: "No sessions found", message: "Pull down to refresh.", tint: .blue)
            } else {
                let current = account.sessions.filter(\.isCurrent)
                let others = account.sessions.filter { !$0.isCurrent }
                if !current.isEmpty {
                    LKSectionTitle("This device")
                    ForEach(current) { sessionCard($0) }
                }
                if !others.isEmpty {
                    LKSectionTitle("Other devices · \(others.count)")
                    ForEach(others) { sessionCard($0) }
                    if others.count > 1 {
                        Text("Don't recognise one? Sign it out, then change your password in Privacy & Security.")
                            .font(.caption2).foregroundStyle(AppTheme.textSecondary).padding(.horizontal, 6)
                    }
                }
            }
        }
        .task { await account.fetchSessions() }
        .refreshable { await account.fetchSessions() }
        .confirmationDialog(
            "Sign out this device?",
            isPresented: Binding(
                get: { pendingRevoke != nil },
                set: { if !$0 { pendingRevoke = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                guard let session = pendingRevoke else { return }
                pendingRevoke = nil
                Task { await account.revokeSession(tokenId: session.tokenId) }
            }
            Button("Cancel", role: .cancel) { pendingRevoke = nil }
        } message: {
            if let session = pendingRevoke, session.isCurrent {
                Text("This will sign you out of Lumisound on this device.")
            } else {
                Text("That device will need to sign in again to use Lumisound.")
            }
        }
    }
}
