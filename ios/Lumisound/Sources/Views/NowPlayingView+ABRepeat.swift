import SwiftUI
import UIKit

extension NowPlayingView {

    // MARK: - AB Repeat

    var abRepeatSection: some View {
        DisclosureGroup(
            isExpanded: $showABRepeat,
            content: {
                VStack(spacing: 12) {
                    // Status row
                    if player.abRepeatEnabled {
                        HStack {
                            Image(systemName: "repeat")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AppTheme.dynamicAccent)
                            Text("Looping \(formatTime(player.abRepeatStart ?? 0)) → \(formatTime(player.abRepeatEnd ?? 0))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(AppTheme.dynamicAccent)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                        .background(AppTheme.dynamicAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    }

                    HStack(spacing: 10) {
                        // A button
                        abButton(
                            label: "A",
                            subtitle: player.abRepeatStart.map { formatTime($0) },
                            isSet: player.abRepeatStart != nil,
                            action: { player.setABStart() }
                        )

                        // Arrow
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)

                        // B button
                        abButton(
                            label: "B",
                            subtitle: player.abRepeatEnd.map { formatTime($0) },
                            isSet: player.abRepeatEnd != nil,
                            action: { player.setABEnd() }
                        )

                        Spacer()

                        // Clear
                        if player.abRepeatStart != nil || player.abRepeatEnd != nil {
                            Button {
                                player.clearABRepeat()
                            } label: {
                                Label("Clear", systemImage: "xmark.circle.fill")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.top, 10)
            },
            label: {
                HStack {
                    Text("A–B Repeat")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    if player.abRepeatEnabled {
                        Circle()
                            .fill(AppTheme.dynamicAccent)
                            .frame(width: 7, height: 7)
                    }
                }
            }
        )
        .tint(AppTheme.dynamicAccent)
        .panelStyle()
    }

    func abButton(label: String, subtitle: String?, isSet: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(isSet ? .white : AppTheme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(isSet ? .white.opacity(0.85) : AppTheme.textSecondary)
                }
            }
            .frame(width: 52, height: 40)
            .background(isSet ? AppTheme.dynamicAccent : AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(LumiMotion.fade(0.2), value: isSet)
    }
}
