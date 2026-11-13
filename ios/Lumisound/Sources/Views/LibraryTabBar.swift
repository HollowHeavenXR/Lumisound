import SwiftUI
import MediaPlayer

// MARK: - Custom Tab Bar

struct LibraryTabBar: View {
    @Binding var selectedTab: LibraryTab
    @Namespace private var pillNamespace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(LumiMotion.settle) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                                .imageScale(.small)
                            Text(tab.rawValue)
                        }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .foregroundStyle(
                                selectedTab == tab ? .white : AppTheme.textSecondary
                            )
                            .background {
                                if selectedTab == tab {
                                    Capsule(style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [AppTheme.dynamicAccent, AppTheme.accentSoft],
                                                startPoint: .topLeading, endPoint: .bottomTrailing
                                            )
                                        )
                                        .shadow(color: AppTheme.dynamicAccent.opacity(0.4), radius: 6, x: 0, y: 3)
                                        .matchedGeometryEffect(id: "libraryTabPill", in: pillNamespace)
                                } else {
                                    Capsule(style: .continuous)
                                        .fill(AppTheme.surface.opacity(0.6))
                                        .overlay(Capsule().stroke(.white.opacity(0.06), lineWidth: 1))
                                }
                            }
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityIdentifier("libraryTab.\(tab.rawValue)")
                }
            }
            .padding(.vertical, 2)
        }
    }
}
