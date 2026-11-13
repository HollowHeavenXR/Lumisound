import SwiftUI
import UIKit

extension NowPlayingView {

    // MARK: - Auto-Radio Toggle

    var autoRadioToggle: some View {
        Button {
            player.autoRadioEnabled.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                Text("Auto-Radio")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Image(systemName: player.autoRadioEnabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
            }
            .foregroundStyle(player.autoRadioEnabled ? AppTheme.dynamicAccent : AppTheme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .adaptiveGlass(
                tint: player.autoRadioEnabled ? AppTheme.dynamicAccent : AppTheme.surface,
                in: Capsule(),
                fallback: .regularMaterial
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        player.autoRadioEnabled ? AppTheme.dynamicAccent.opacity(0.4) : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        // Long-press: how adventurous Lumisound Radio is (core RadioSession mode).
        .contextMenu {
            ForEach([("balanced", "Balanced", "dial.medium"), ("familiar", "More of what I know", "heart"),
                     ("discover", "Discover new music", "safari")], id: \.0) { mode in
                Button {
                    UserDefaults.standard.set(mode.0, forKey: "radio_mode")
                } label: {
                    Label(mode.1, systemImage: (UserDefaults.standard.string(forKey: "radio_mode") ?? "balanced") == mode.0 ? "checkmark" : mode.2)
                }
            }
        }
        .animation(LumiMotion.snap, value: player.autoRadioEnabled)
    }
}
