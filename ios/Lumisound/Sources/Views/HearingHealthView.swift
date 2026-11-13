import SwiftUI

/// Surfaces Apple's own Headphone Audio Levels data (read via HealthKit —
/// see HearingHealthService) alongside Lumisound's own Volume Boost usage.
/// Not a from-scratch loudness meter — see that service's doc comment for
/// why this reads Apple's measurement rather than estimating its own.
struct HearingHealthView: View {
    @ObservedObject private var service = HearingHealthService.shared

    var body: some View {
        ScrollView {
            if !service.isHealthDataAvailable {
                EmptyStateView(
                    icon: "ear.trianglebadge.exclamationmark",
                    title: "Health Data Unavailable",
                    message: "This device doesn't support Health data."
                )
                .padding(.top, 60)
            } else if !service.isAuthorized {
                permissionPrompt
            } else if service.isLoading && service.dailyExposure.isEmpty {
                ProgressView().padding(.top, 60)
            } else if service.dailyExposure.allSatisfy({ $0.averageDecibels == nil }) {
                EmptyStateView(
                    icon: "ear",
                    title: "No Headphone Data Yet",
                    message: "Listen with headphones for a few days and your exposure will show up here — this comes from iOS's own Headphone Audio Levels feature (Settings → Privacy & Security → Health → Headphone Audio), not Lumisound itself."
                )
                .padding(.top, 60)
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    LKHero(title: "Hearing Health", subtitle: "Your headphone levels from Health, next to your Volume Boost use.", icon: "ear.fill", tint: .green)
                    summaryCard
                    weekChart
                    if let summary = service.boostCorrelationSummary {
                        correlationCard(summary)
                    }
                    disclaimer
                }
                .padding(16)
            }
        }
        .background(GalleryBackgroundView().ignoresSafeArea())
        .navigationTitle("Hearing Health")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if service.isAuthorized {
                await service.refresh()
            }
        }
    }

    private var permissionPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "ear.badge.waveform")
                .font(.system(size: 44))
                .foregroundStyle(AppTheme.dynamicAccent)
            Text("Hearing Health")
                .font(AppTheme.headlineFont(size: 20))
                .foregroundStyle(AppTheme.textPrimary)
            Text("Lumisound can read your headphone audio exposure from Health — measured by iOS itself, not estimated by this app — and show you how it lines up with your own Volume Boost usage. Nothing is written back to Health, and nothing leaves your device.")
                .font(AppTheme.bodyFont(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await service.requestAuthorization() }
            } label: {
                Text("Connect Health")
                    .font(AppTheme.bodyFont(size: 15).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(AppTheme.dynamicAccent, in: Capsule())
            }
        }
        .padding(24)
        .padding(.top, 60)
    }

    private var summaryCard: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(service.daysOverThresholdThisWeek)")
                    .font(AppTheme.headlineFont(size: 28))
                    .foregroundStyle(service.daysOverThresholdThisWeek > 0 ? .orange : AppTheme.textPrimary)
                Text("days this week at or above \(Int(HearingHealthService.elevatedExposureThresholdDB)) dB")
                    .font(AppTheme.bodyFont(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
        }
        .padding(16)
        .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var weekChart: some View {
        let days = Array(service.dailyExposure.suffix(14))
        let maxDB = max(days.compactMap(\.averageDecibels).max() ?? 90, HearingHealthService.elevatedExposureThresholdDB + 10)

        return VStack(alignment: .leading, spacing: 10) {
            Text("LAST 14 DAYS")
                .font(AppTheme.bodyFont(size: 11))
                .foregroundStyle(AppTheme.textSecondary)
                .kerning(0.8)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(days) { day in
                    VStack(spacing: 4) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(AppTheme.elevatedSurface)
                                .frame(height: 90)
                            if let db = day.averageDecibels {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(db >= HearingHealthService.elevatedExposureThresholdDB
                                          ? Color.orange
                                          : AppTheme.dynamicAccent)
                                    .frame(height: max(4, 90 * CGFloat(db / maxDB)))
                                    .overlay(alignment: .top) {
                                        if day.volumeBoostWasActive {
                                            Circle()
                                                .fill(.white)
                                                .frame(width: 5, height: 5)
                                                .padding(.top, 2)
                                        }
                                    }
                            }
                        }
                        Text(shortDay(day.day))
                            .font(.system(size: 9))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
            }
            HStack(spacing: 14) {
                legendItem(color: AppTheme.dynamicAccent, label: "Exposure")
                legendItem(color: .orange, label: "Elevated (\(Int(HearingHealthService.elevatedExposureThresholdDB))+ dB)")
                HStack(spacing: 5) {
                    Circle().fill(.white).frame(width: 5, height: 5)
                    Text("Volume Boost used").font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
        .padding(16)
        .background(AppTheme.elevatedSurface.opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label).font(.system(size: 10)).foregroundStyle(AppTheme.textSecondary)
        }
    }

    private func correlationCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb")
                .foregroundStyle(.orange)
            Text(text)
                .font(AppTheme.bodyFont(size: 13))
                .foregroundStyle(AppTheme.textPrimary)
        }
        .padding(14)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var disclaimer: some View {
        Text("Exposure data comes from iOS's own Headphone Audio Levels feature, not from Lumisound measuring your audio — a third-party app has no way to know your device's real acoustic output, only iOS does. This is an informational correlation, not medical advice.")
            .font(.system(size: 11))
            .foregroundStyle(AppTheme.textSecondary.opacity(0.8))
    }

    private func shortDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: date)
    }
}
