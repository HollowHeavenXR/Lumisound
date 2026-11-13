import SwiftUI

/// Live emoji reactions during a Listen Together (SharePlay) session — a
/// small picker row plus a floating-burst overlay, both driven by
/// `SharePlayCoordinator.reactionReceived`/`sendReaction(_:)` (see
/// `SharePlayCoordinator+Reactions.swift`). Distinct from the shared
/// suggest-and-vote queue (`SharePlayCoordinator+Queue.swift`): this is a
/// purely in-the-moment social layer with nothing persisted — closer to
/// "everyone claps at the drop together" than "decide what plays next".

/// A row of tappable emoji, shown only while a session is active — see
/// `NowPlayingView+ScrollContent.swift` for where this sits on screen.
struct ListenTogetherReactionBar: View {
    @EnvironmentObject private var sharePlay: SharePlayCoordinator

    private static let emojiOptions = ["🔥", "❤️", "😂", "🎉", "👏", "😮"]

    var body: some View {
        if sharePlay.isSessionActive {
            HStack(spacing: 14) {
                ForEach(Self.emojiOptions, id: \.self) { emoji in
                    Button {
                        sharePlay.sendReaction(emoji)
                    } label: {
                        Text(emoji)
                            .font(.system(size: 22))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(AppTheme.elevatedSurface, in: Capsule())
            .frame(maxWidth: .infinity)
        }
    }
}

/// Floating emoji burst overlay — each incoming reaction spawns a
/// short-lived emoji that drifts upward and fades, then removes itself.
/// Sits in an `.overlay` on the whole Now Playing screen (see
/// `NowPlayingView.swift`), not scoped to the reaction bar itself, so a
/// reaction is visible no matter where on the screen you're scrolled to.
struct ListenTogetherReactionsOverlay: View {
    @EnvironmentObject private var sharePlay: SharePlayCoordinator
    @State private var floating: [FloatingReaction] = []

    private struct FloatingReaction: Identifiable {
        let id = UUID()
        let emoji: String
        let xOffset: CGFloat
    }

    var body: some View {
        ZStack {
            ForEach(floating) { reaction in
                Text(reaction.emoji)
                    .font(.system(size: 36))
                    .offset(x: reaction.xOffset)
                    .modifier(FloatingReactionAnimator())
            }
        }
        .allowsHitTesting(false)
        .onReceive(sharePlay.reactionReceived) { emoji in
            spawn(emoji)
        }
    }

    private func spawn(_ emoji: String) {
        let reaction = FloatingReaction(emoji: emoji, xOffset: CGFloat.random(in: -60...60))
        floating.append(reaction)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            floating.removeAll { $0.id == reaction.id }
        }
    }
}

/// Drives the upward-drift + fade for one floating reaction via an
/// implicit `.onAppear` animation — simpler than a `TimelineView` here
/// since each reaction is a genuine one-shot animation, not a continuous
/// loop like `KenBurnsModifier`'s pan/zoom.
private struct FloatingReactionAnimator: ViewModifier {
    @State private var animate = false

    func body(content: Content) -> some View {
        content
            .offset(y: animate ? -160 : 0)
            .opacity(animate ? 0 : 1)
            .onAppear {
                withAnimation(LumiMotion.glide(1.6)) {
                    animate = true
                }
            }
    }
}
