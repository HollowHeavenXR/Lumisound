import SwiftUI

// MARK: - Avatar frame styles
//
// Purely cosmetic, purely client-rendered decoration around a profile
// avatar — no image assets, no server-stored pixels, just SwiftUI strokes/
// gradients/animation layered outside the avatar's existing base ring (see
// ProfileHeaderCard). Validated server-side against this exact set
// (`_VALID_AVATAR_FRAMES` in main.py) so a malformed value can never reach
// the client; keep this list in sync if it ever changes.
enum AvatarFrameStyle: String, CaseIterable, Identifiable {
    case none, ring, glow, dashed, pulse, gradient
    // Second wave. Each is built from the same accent pair as the originals so
    // a frame always belongs to the profile wearing it rather than introducing
    // a palette of its own.
    case double, beads, spin, orbit, halo, arc

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:     return "None"
        case .ring:     return "Ring"
        case .glow:     return "Glow"
        case .dashed:   return "Dashed"
        case .pulse:    return "Pulse"
        case .gradient: return "Gradient"
        case .double:   return "Double"
        case .beads:    return "Beads"
        case .spin:     return "Spin"
        case .orbit:    return "Orbit"
        case .halo:     return "Halo"
        case .arc:      return "Arc"
        }
    }

    static func from(_ raw: String?) -> AvatarFrameStyle {
        AvatarFrameStyle(rawValue: raw ?? "none") ?? .none
    }
}

/// Renders the decorative frame around an avatar of the given `diameter`,
/// sized to sit just outside the avatar's own edge (and, for `.ring`'s base
/// stroke inside `ProfileHeaderCard`, outside that too). `mainTint`/`subTint`
/// are the profile's own accent colors — every style reuses them rather than
/// a fixed palette, so a frame always matches the rest of the profile.
struct AvatarFrameOverlay: View {
    let style: AvatarFrameStyle
    let diameter: CGFloat
    let mainTint: Color
    let subTint: Color

    @State private var isPulsing = false

    var body: some View {
        switch style {
        case .none:
            EmptyView()
        case .ring:
            Circle()
                .stroke(mainTint, lineWidth: 3)
                .frame(width: diameter + 10, height: diameter + 10)
        case .glow:
            Circle()
                .fill(mainTint.opacity(0.55))
                .frame(width: diameter + 6, height: diameter + 6)
                .blur(radius: 10)
        case .dashed:
            Circle()
                .stroke(mainTint, style: StrokeStyle(lineWidth: 2.5, dash: [5, 4]))
                .frame(width: diameter + 12, height: diameter + 12)
        case .pulse:
            Circle()
                .stroke(mainTint, lineWidth: 2.5)
                .frame(width: diameter + 10, height: diameter + 10)
                .scaleEffect(isPulsing ? 1.18 : 1.0)
                .opacity(isPulsing ? 0 : 0.8)
                .animation(LumiMotion.glide(1.6).repeatForever(autoreverses: false), value: isPulsing)
                .onAppear { isPulsing = true }
        case .gradient:
            Circle()
                .stroke(
                    AngularGradient(colors: [mainTint, subTint, mainTint], center: .center),
                    lineWidth: 3.5
                )
                .frame(width: diameter + 10, height: diameter + 10)

        case .double:
            // Two rings at different radii, one per accent, so the pair reads as
            // deliberate rather than as a single ring that happens to be thick.
            ZStack {
                Circle()
                    .stroke(mainTint, lineWidth: 2.5)
                    .frame(width: diameter + 14, height: diameter + 14)
                Circle()
                    .stroke(subTint.opacity(0.85), lineWidth: 1.5)
                    .frame(width: diameter + 6, height: diameter + 6)
            }

        case .beads:
            // A dotted ring. Round caps with a near-zero dash length turn each
            // dash into a circle, which is how you get evenly-spaced dots around
            // a curve without positioning any of them by hand.
            Circle()
                .stroke(
                    mainTint,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [0.01, 9])
                )
                .frame(width: diameter + 12, height: diameter + 12)

        case .spin:
            // A gradient arc that rotates continuously. Driven by TimelineView
            // rather than a repeating `.animation`, matching how the decoration
            // and effect overlays animate — the angle is a pure function of the
            // clock, so nothing has to be started, stopped, or kept in sync.
            TimelineView(.animation(minimumInterval: LumiMotion.frame)) { timeline in
                let angle = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 3) / 3 * 360
                Circle()
                    .trim(from: 0, to: 0.65)
                    .stroke(
                        AngularGradient(colors: [mainTint.opacity(0), mainTint, subTint], center: .center),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(angle))
                    .frame(width: diameter + 12, height: diameter + 12)
            }

        case .orbit:
            // A faint track with a single dot travelling around it.
            TimelineView(.animation(minimumInterval: LumiMotion.frame)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let angle = t.truncatingRemainder(dividingBy: 4) / 4 * 2 * .pi
                let radius = (diameter + 14) / 2
                ZStack {
                    Circle()
                        .stroke(mainTint.opacity(0.25), lineWidth: 1)
                        .frame(width: diameter + 14, height: diameter + 14)
                    Circle()
                        .fill(subTint)
                        .frame(width: 6, height: 6)
                        .offset(x: radius * cos(angle), y: radius * sin(angle))
                }
                .frame(width: diameter + 20, height: diameter + 20)
            }

        case .halo:
            // Two glows at different spreads. A single blur reads as a smudge;
            // a tight bright core inside a wide soft one reads as light.
            ZStack {
                Circle()
                    .fill(subTint.opacity(0.35))
                    .frame(width: diameter + 16, height: diameter + 16)
                    .blur(radius: 14)
                Circle()
                    .fill(mainTint.opacity(0.6))
                    .frame(width: diameter + 4, height: diameter + 4)
                    .blur(radius: 5)
            }

        case .arc:
            // A single thick sweep with a visible gap, like a progress ring
            // stopped partway — the most graphic of the set.
            Circle()
                .trim(from: 0.08, to: 0.67)
                .stroke(
                    LinearGradient(colors: [mainTint, subTint],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: diameter + 12, height: diameter + 12)
        }
    }
}

/// A row of tappable frame-style previews, mirroring `AccentColorPickerView`
/// exactly — same picker shape, just previewing frame styles on a small
/// swatch avatar instead of a plain color circle.
struct AvatarFramePickerView: View {
    let mainTint: Color
    let subTint: Color
    @Binding var selected: AvatarFrameStyle

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(AvatarFrameStyle.allCases) { style in
                Button {
                    withAnimation(LumiMotion.snap) {
                        selected = style
                    }
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            AvatarFrameOverlay(style: style, diameter: 40, mainTint: mainTint, subTint: subTint)
                            Circle()
                                .fill(mainTint.opacity(0.25))
                                .frame(width: 40, height: 40)
                                .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1))
                        }
                        .frame(width: 54, height: 54)

                        Text(style.label)
                            .font(AppTheme.bodyFont(size: 11))
                            .foregroundStyle(selected == style ? mainTint : AppTheme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
