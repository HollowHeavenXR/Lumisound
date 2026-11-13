import SwiftUI
import Combine

/// Live emoji reactions in a Listen Together room — a small picker row plus
/// a floating-burst overlay, both driven by `ListenRoomService.reactions` /
/// `sendReaction(_:)` (pushed to the room over the live socket by the
/// bridge, nothing stored). Distinct from the room's suggest-and-vote queue:
/// this is the in-the-moment layer — everyone claps at the drop together.

/// A row of tappable emoji, shown only while a session is active — see
/// `NowPlayingView+ScrollContent.swift` for where this sits on screen.
struct ListenTogetherReactionBar: View {
    @ObservedObject private var rooms = ListenRoomService.shared

    private static let emojiOptions = ["🔥", "❤️", "😂", "🎉", "👏", "😮"]

    var body: some View {
        if rooms.isInRoom {
            HStack(spacing: 14) {
                ForEach(Self.emojiOptions, id: \.self) { emoji in
                    Button {
                        rooms.sendReaction(emoji)
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
    private let rooms = ListenRoomService.shared
    @State private var floating: [FloatingReaction] = []

    private struct FloatingReaction: Identifiable {
        let id = UUID()
        let emoji: String
        let from: String
        let xOffset: CGFloat
    }

    var body: some View {
        ZStack {
            ForEach(floating) { reaction in
                VStack(spacing: 2) {
                    Text(reaction.emoji).font(.system(size: 36))
                    Text(reaction.from)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.35), in: Capsule())
                }
                .offset(x: reaction.xOffset)
                    .modifier(FloatingReactionAnimator())
            }
        }
        .allowsHitTesting(false)
        .onReceive(rooms.reactions.receive(on: DispatchQueue.main)) { r in
            spawn(r.emoji, from: r.from)
        }
    }

    private func spawn(_ emoji: String, from: String) {
        let reaction = FloatingReaction(emoji: emoji, from: from, xOffset: CGFloat.random(in: -60...60))
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
