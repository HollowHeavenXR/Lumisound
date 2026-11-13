import SwiftUI

/// One-shot confetti burst — pieces fall from the top of the view and fade
/// out over a few seconds. Bind `isActive` to a `@State` that the caller
/// flips back to `false` after the burst has had time to play out (see
/// `AchievementsView.checkForNewBadges`); this view doesn't reset itself.
struct ConfettiOverlay: View {
    let isActive: Bool
    @State private var startDate: Date?

    private static let pieceCount = 36

    var body: some View {
        GeometryReader { geo in
            if isActive, let startDate {
                TimelineView(.animation(minimumInterval: LumiMotion.frame)) { timeline in
                    let elapsed = timeline.date.timeIntervalSince(startDate)
                    ZStack {
                        ForEach(0..<Self.pieceCount, id: \.self) { i in
                            ConfettiPiece(index: i, elapsed: elapsed, size: geo.size)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: isActive) { active in
            if active { startDate = Date() }
        }
    }
}

private struct ConfettiPiece: View {
    let index: Int
    let elapsed: TimeInterval
    let size: CGSize

    private static let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .pink]

    var body: some View {
        var rng = SeededRandom(seed: UInt64(index) &* 7_919 &+ 104_729)
        let startX: CGFloat = CGFloat(rng.nextDouble()) * size.width
        let fallSpeed: CGFloat = 90 + CGFloat(rng.nextDouble()) * 140    // points/sec
        let horizontalDrift: CGFloat = CGFloat(rng.nextDouble()) * 50 - 25
        let spinSpeed: Double = 120 + Double(rng.nextDouble()) * 300     // deg/sec
        let startDelay: Double = Double(rng.nextDouble()) * 0.5
        let color = Self.colors[index % Self.colors.count]

        let localElapsed = max(0, elapsed - startDelay)
        let y: CGFloat = -20 + fallSpeed * CGFloat(localElapsed)
        let x: CGFloat = startX + horizontalDrift * CGFloat(localElapsed)
        let rotation = spinSpeed * localElapsed
        let fadeStartSeconds = 2.0
        let opacity: Double = localElapsed < fadeStartSeconds
            ? 1.0
            : max(0, 1.0 - (localElapsed - fadeStartSeconds) / 0.6)

        return RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(color)
            .frame(width: 7, height: 10)
            .rotationEffect(.degrees(rotation))
            .position(x: x, y: y)
            .opacity(opacity)
    }
}
