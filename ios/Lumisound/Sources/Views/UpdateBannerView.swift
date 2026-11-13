import SwiftUI

// MARK: - UpdateBannerView

struct UpdateBannerView: View {
    @EnvironmentObject private var updater: UpdateService
    @State private var isDismissed = false

    var body: some View {
        if updater.updateAvailable && !isDismissed {
            bannerContent
        }
    }

    private var bannerContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 1) {
                if let latest = updater.latestVersion {
                    Text("Version \(latest) available")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Text("Update available")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }

            Spacer(minLength: 0)

            Button {
                updater.openReleasePage()
            } label: {
                Text("Download")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.dynamicAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(LumiMotion.glide(0.2)) {
                    isDismissed = true
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .background(
            LinearGradient(
                colors: [AppTheme.dynamicAccent, AppTheme.dynamicAccent.opacity(0.8)],
                startPoint: .leading,
                endPoint: .trailing
            ),
            in: RoundedRectangle(cornerRadius: 0)
        )
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }
}
