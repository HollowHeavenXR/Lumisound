import SwiftUI
import UniformTypeIdentifiers

// MARK: - StaggeredFadeInModifier

/// Fades each result row in with a small per-index delay whenever `token` changes.
struct StaggeredFadeInModifier: ViewModifier {
    let index: Int
    let token: UUID
    @State private var visible: Bool = false

    private var delay: Double { Double(min(index, 19)) * 0.04 }

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            // Small upward slide alongside the fade — rows settle into place
            // rather than just materializing, giving the staggered reveal a
            // bit more life without anything approaching a spring-per-frame
            // cost.
            .offset(y: visible ? 0 : 6)
            .animation(
                LumiMotion.glide(0.3).delay(delay),
                value: visible
            )
            .onAppear { visible = true }
            .onChange(of: token) { _ in
                visible = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    visible = true
                }
            }
    }
}
