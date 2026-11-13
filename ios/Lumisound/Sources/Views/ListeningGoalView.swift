import SwiftUI

/// Set and track a weekly listening-time goal — see
/// `ListeningGoalService`'s doc comment for how this differs from
/// Achievements' retrospective streaks/badges.
struct ListeningGoalView: View {
    @EnvironmentObject private var account: AccountService
    @ObservedObject private var goal = ListeningGoalService.shared

    @State private var draftMinutes: Int = 300 // 5 hours, a reasonable default suggestion

    private let quickGoals = [120, 300, 600, 900, 1200]

    var body: some View {
        LKPage(title: "Listening Goal", subtitle: "A weekly target, measured from the last 7 days.", icon: "target", tint: .green) {
            if let target = goal.targetMinutes {
                progressCard(target: target)
                    .padding(.vertical, 8)
                    .background(LKCardBackground(tint: goal.isGoalMet ? .green : nil))
                LKCard(title: "Adjust") {
                    LKControlRow(icon: "target", tint: .green, title: "Weekly goal", value: formatted(target)) {
                        Stepper("", value: Binding(get: { target }, set: { goal.targetMinutes = $0 }), in: 30...4200, step: 30).labelsHidden()
                    }
                    LKDivider()
                    LKButtonRow(icon: "xmark.circle", title: "Remove Goal", destructive: true) { goal.targetMinutes = nil }
                }
            } else {
                LKCard(title: "Pick a goal") {
                    VStack(alignment: .leading, spacing: 12) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(quickGoals, id: \.self) { m in
                                    Button { draftMinutes = m } label: { LKChip(title: formatted(m), selected: draftMinutes == m, tint: .green) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                        LKControlRow(icon: "slider.horizontal.3", tint: .green, title: "Custom", value: formatted(draftMinutes)) {
                            Stepper("", value: $draftMinutes, in: 30...4200, step: 30).labelsHidden()
                        }
                        Text("That's about \(formatted(draftMinutes / 7)) a day.").font(.caption).foregroundStyle(AppTheme.textSecondary)
                    }
                }
                LKPrimaryButton(title: "Set Weekly Goal", icon: "target", tint: .green) { goal.targetMinutes = draftMinutes }
            }
        }
        .task { await goal.refresh(account: account) }
        .refreshable { await goal.refresh(account: account) }
    }

    private func progressCard(target: Int) -> some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(AppTheme.elevatedSurface, lineWidth: 12)
                Circle()
                    .trim(from: 0, to: goal.progressFraction)
                    .stroke(
                        goal.isGoalMet ? Color.green : AppTheme.dynamicAccent,
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.5), value: goal.progressFraction)
                VStack(spacing: 2) {
                    Text(formatted(goal.progressMinutes))
                        .font(.title2.bold())
                        .foregroundStyle(AppTheme.textPrimary)
                    Text("of \(formatted(target))")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .frame(width: 140, height: 140)
            .padding(.top, 8)

            if goal.isGoalMet {
                Label("Goal reached this week", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
            } else if !goal.hasLoaded {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func formatted(_ minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 && mins > 0 { return "\(hours)h \(mins)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(mins)m"
    }
}
