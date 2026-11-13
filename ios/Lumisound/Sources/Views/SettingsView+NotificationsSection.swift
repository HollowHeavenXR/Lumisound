import SwiftUI
import UIKit

// MARK: - SettingsView Notifications Entry Point

extension SettingsView {

    // MARK: — Notifications Section

    var notificationsSection: some View {
        Section {
            NavigationLink(destination: NotificationsSettingsView()) {
                HStack {
                    Label("Notifications", systemImage: "bell.badge")
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    notificationsStatusPill
                }
            }
        } header: {
            sectionHeader("Notifications", icon: "bell.badge.fill", tint: .orange)
        }
        .listRowBackground(tintedRowBackground(.orange))
        .animation(.easeInOut(duration: 0.2), value: notificationService.isEnabled)
        .animation(.easeInOut(duration: 0.2), value: notificationService.isAuthorized)
    }

    @ViewBuilder
    private var notificationsStatusPill: some View {
        if !notificationService.isEnabled {
            statusPill(text: "Off", color: AppTheme.textSecondary)
        } else if !notificationService.isAuthorized {
            statusPill(text: "Needs Access", color: AppTheme.warning)
        } else {
            statusPill(text: "On", color: AppTheme.success)
        }
    }

    private func statusPill(text: String, color: Color) -> some View {
        Text(text)
            .font(AppTheme.bodyFont(size: 12))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
    }
}

// MARK: - NotificationsSettingsView
//
// Dedicated Settings screen: OS authorization status (with a deep link to
// iOS Settings when denied), the master on/off switch, and a per-topic
// preference toggle for every registered `NotificationTopic` — grouped by
// `NotificationTopicGroup`, each group collapsible for a lighter-feeling list
// once more topics accumulate (e.g. once the social workstream registers its
// own friend-activity topics under `.social`).

struct NotificationsSettingsView: View {
    @ObservedObject private var service = NotificationService.shared
    /// nil = every group.
    @State private var group: NotificationTopicGroup?

    var body: some View {
        LKPage(title: "Notifications", subtitle: "Choose exactly what Lumisound may tell you about.",
               icon: "bell.badge.fill", tint: .orange, showsHero: false) {
            statusCard
            if let error = service.lastAuthorizationError {
                LKBanner(icon: "exclamationmark.triangle.fill", text: error, tint: AppTheme.warning)
            }
            groupChips
            ForEach(visibleGroups, id: \.group) { entry in
                groupCard(entry.group, entry.topics)
            }
        }
        .task {
            // Re-checks (never re-prompts once determined) so the status is
            // accurate the moment this opens, e.g. after granting access in iOS Settings.
            await service.requestAuthorization()
        }
    }

    // MARK: Status + master switch

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(statusColor.opacity(0.18)).frame(width: 58, height: 58)
                    Image(systemName: statusIcon)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .symbolEffect(.bounce, value: service.isEnabled)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle).font(.title3.bold()).foregroundStyle(AppTheme.textPrimary)
                    Text(statusDetail).font(.caption).foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Toggle(isOn: $service.isEnabled) {
                Text("Allow Lumisound notifications").font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.textPrimary)
            }
            .tint(.orange)
            if service.isEnabled && !service.isAuthorized {
                LKPrimaryButton(title: "Open iOS Settings", icon: "gearshape.fill", tint: .orange) { openSystemSettings() }
            }
            Text("\(enabledCount) of \(NotificationTopicRegistry.grouped.flatMap(\.topics).count) alerts on")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(16)
        .background(LKCardBackground(tint: .orange))
        .animation(.easeInOut(duration: 0.2), value: statusTitle)
    }

    private var enabledCount: Int {
        NotificationTopicRegistry.grouped.flatMap(\.topics).filter { service.isTopicEnabled($0.id) }.count
    }

    private var statusIcon: String {
        guard service.isEnabled else { return "bell.slash" }
        return service.isAuthorized ? "bell.badge.fill" : "bell.slash.fill"
    }

    private var statusColor: Color {
        guard service.isEnabled else { return AppTheme.textSecondary }
        return service.isAuthorized ? AppTheme.success : AppTheme.warning
    }

    private var statusTitle: String {
        guard service.isEnabled else { return "Notifications off" }
        return service.isAuthorized ? "You're in the loop" : "iOS is blocking alerts"
    }

    private var statusDetail: String {
        guard service.isEnabled else { return "Nothing will be sent. Your choices below are kept for when you turn it back on." }
        return service.isAuthorized
            ? "Alerts arrive in the background and while Lumisound is open."
            : "Notifications are off for Lumisound in iOS Settings, so none of the alerts below can arrive."
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: Groups

    private var visibleGroups: [(group: NotificationTopicGroup, topics: [NotificationTopic])] {
        NotificationTopicRegistry.grouped
            .filter { group == nil || $0.group == group }
            .map { (group: $0.group, topics: $0.topics) }
    }

    private var groupChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { withAnimation { group = nil } } label: {
                    LKChip(title: "All", icon: "square.grid.2x2", selected: group == nil, tint: .orange)
                }
                .buttonStyle(.plain)
                ForEach(NotificationTopicRegistry.grouped, id: \.group) { entry in
                    Button { withAnimation { group = entry.group } } label: {
                        LKChip(title: entry.group.displayName, icon: entry.group.icon, selected: group == entry.group, tint: .orange)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func groupCard(_ group: NotificationTopicGroup, _ topics: [NotificationTopic]) -> some View {
        let on = topics.filter { service.isTopicEnabled($0.id) }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(group.displayName, systemImage: group.icon)
                    .font(.system(size: 11, weight: .bold))
                    .textCase(.uppercase)
                    .kerning(1)
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
                Button(on == topics.count ? "Mute all" : "Turn all on") {
                    let target = on != topics.count
                    for t in topics { service.setTopicEnabled(target, for: t.id) }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .disabled(!service.isEnabled)
            }
            .padding(.horizontal, 6)
            VStack(spacing: 0) {
                ForEach(Array(topics.enumerated()), id: \.element.id) { i, topic in
                    LKToggle(icon: topic.icon, tint: .orange, title: topic.displayName, subtitle: topic.detail, isOn: Binding(
                        get: { service.isTopicEnabled(topic.id) },
                        set: { service.setTopicEnabled($0, for: topic.id) }
                    ))
                    .disabled(!service.isEnabled)
                    .opacity(service.isEnabled ? 1 : 0.5)
                    if i < topics.count - 1 { LKDivider() }
                }
            }
            .padding(14)
            .background(LKCardBackground())
        }
    }
}
