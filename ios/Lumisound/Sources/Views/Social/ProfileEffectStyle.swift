import SwiftUI

// MARK: - Profile effect styles
//
// Discord-style "Profile Effect": a looping animation overlaid across the
// WHOLE profile banner (as opposed to `AvatarDecorationStyle`, which is
// scoped to just the avatar circle). Same "purely cosmetic, purely
// client-rendered, always tinted from the profile's own accent colors"
// contract as that type — see its doc comment for the full reasoning, not
// repeated here. Validated server-side against this exact set
// (`_VALID_PROFILE_EFFECTS` in main.py) so a malformed value can never reach
// the client — keep this list in sync if it ever changes. Raw values are
// camelCase (not lowercased) to match the server's literal strings exactly,
// same convention `DuplicateReason.apiValue` uses.
enum ProfileEffectStyle: String, CaseIterable, Identifiable {
    case none, blastOff, aurora, shootingStars, confetti, rain
    // Second wave. `waveform` and `pulse` are the two that belong specifically
    // to a music app — the rest of the set could sit on any profile.
    case waveform, starfield, bokeh, snowfall, pulse

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:          return "None"
        case .blastOff:      return "Blast Off"
        case .aurora:        return "Aurora"
        case .shootingStars: return "Shooting Stars"
        case .confetti:      return "Confetti"
        case .rain:          return "Rain"
        case .waveform:      return "Waveform"
        case .starfield:     return "Starfield"
        case .bokeh:         return "Bokeh"
        case .snowfall:      return "Snowfall"
        case .pulse:         return "Pulse"
        }
    }

    static func from(_ raw: String?) -> ProfileEffectStyle {
        ProfileEffectStyle(rawValue: raw ?? "none") ?? .none
    }
}

/// Same deterministic-hash idea as `AvatarDecorationOverlay`'s private
/// `DecorationParticle` — kept as a separate (identical-shaped) type rather
/// than sharing one across files so each overlay's particle count/seeding
/// stays independent and neither file needs to expose the other's internals.
private struct EffectParticle {
    let seed: Double

    func hash(_ salt: Double) -> Double {
        let x = sin(seed * 12.9898 + salt * 78.233) * 43758.5453
        return x - floor(x)
    }
}

/// Renders the looping effect animation across a banner-sized area —
/// callers are expected to clip this to the same shape as the banner itself
/// (see `ProfileHeaderCard`), same as the banner image/gradient it sits on
/// top of. `mainTint`/`subTint` are the profile's own accent colors.
struct ProfileEffectOverlay: View {
    let style: ProfileEffectStyle
    let mainTint: Color
    let subTint: Color

    private static let particleCount = 16
    private let particles: [EffectParticle] = (0..<ProfileEffectOverlay.particleCount).map {
        EffectParticle(seed: Double($0) + 1)
    }

    var body: some View {
        if style == .none {
            EmptyView()
        } else {
            TimelineView(.animation(minimumInterval: LumiMotion.frame)) { timeline in
                Canvas { context, size in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    if style == .aurora {
                        drawAurora(in: &context, size: size, time: time)
                    } else {
                        for particle in particles {
                            draw(particle, in: &context, size: size, time: time)
                        }
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Same "plain `Double` math, `CGFloat` only at CGPoint/CGRect
    /// construction" discipline as `AvatarDecorationOverlay.draw` — see its
    /// doc comment for why.
    private func draw(_ particle: EffectParticle, in context: inout GraphicsContext, size: CGSize, time: Double) {
        let w = Double(size.width), h = Double(size.height)
        let mix = particle.hash(1)
        let tint = mainTint.mixed(with: subTint, amount: mix)

        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: CGFloat(x), y: CGFloat(y)) }

        switch style {
        case .none, .aurora:
            return

        case .blastOff:
            // Fast upward streaks with a fading trail — a short line segment
            // (not a dot) so the motion itself reads at a glance, not just
            // the endpoint position.
            let speed = 0.5 + particle.hash(2) * 0.5
            let startX = particle.hash(3) * w
            let sway = (particle.hash(4) - 0.5) * 14
            let progress = (time * speed + particle.hash(5)).truncatingRemainder(dividingBy: 1.0)
            let y = h * (1 - progress) - h * 0.1
            let trailLength = 22.0
            let x = startX + progress * sway
            guard y > -trailLength, y < h + trailLength else { return }
            var path = Path()
            path.move(to: point(x, y + trailLength))
            path.addLine(to: point(x, y))
            // Fades in from the bottom and out near the top, so a streak
            // never looks like it's popping in/out mid-banner.
            let edgeFade = min(1, min(progress, 1 - progress) * 6)
            context.stroke(
                path,
                with: .color(tint.opacity(0.55 * edgeFade)),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
            )

        case .shootingStars:
            // Most of each particle's cycle it's invisible — a "burst
            // window" (`burstStart..<burstStart + burstLength`) makes it
            // streak diagonally across just once per loop, rather than
            // every particle streaking constantly and overwhelming the banner.
            let cycle = 3.5 + particle.hash(2) * 2.5
            let burstStart = particle.hash(3)
            let burstLength = 0.12
            let t = (time / cycle + particle.hash(4)).truncatingRemainder(dividingBy: 1.0)
            guard t >= burstStart, t < burstStart + burstLength else { return }
            let localT = (t - burstStart) / burstLength
            let startX = particle.hash(5) * w * 0.6
            let startY = particle.hash(6) * h * 0.4
            let travel = 60.0
            let headX = startX + localT * travel
            let headY = startY + localT * travel * 0.5
            let tailX = headX - 18
            let tailY = headY - 9
            var path = Path()
            path.move(to: point(tailX, tailY))
            path.addLine(to: point(headX, headY))
            let fadeOut = 1 - localT
            context.stroke(
                path,
                with: .color(tint.opacity(0.8 * fadeOut)),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
            )
            let headRadius = 1.6
            let headRect = CGRect(
                x: CGFloat(headX - headRadius), y: CGFloat(headY - headRadius),
                width: CGFloat(headRadius * 2), height: CGFloat(headRadius * 2)
            )
            context.fill(Path(ellipseIn: headRect), with: .color(tint.opacity(0.9 * fadeOut)))

        case .confetti:
            // Small falling rectangles with a slow spin — the "spin" is a
            // width squash (cos of an angle) rather than a real rotation
            // transform, which reads convincingly as tumbling at this size
            // without needing a per-particle CGAffineTransform.
            let fallSpeed = 0.15 + particle.hash(2) * 0.12
            let startX = particle.hash(3)
            let swayAmount = 0.05 + particle.hash(4) * 0.05
            let phase = particle.hash(5) * .pi * 2
            let spinSpeed = 2 + particle.hash(6) * 3
            let fallProgress = (time * fallSpeed + particle.hash(7)).truncatingRemainder(dividingBy: 1.0)
            let x = (startX + sin(time * 0.7 + phase) * swayAmount).truncatingRemainder(dividingBy: 1) * w
            let y = fallProgress * h * 1.2 - h * 0.1
            guard y > -6, y < h + 6 else { return }
            let spin = cos(time * spinSpeed + phase)
            let pieceWidth = max(0.6, abs(spin) * 3.5)
            let pieceHeight = 5.0
            let pieceRect = CGRect(
                x: CGFloat(x - pieceWidth / 2), y: CGFloat(y - pieceHeight / 2),
                width: CGFloat(pieceWidth), height: CGFloat(pieceHeight)
            )
            // Alternates toward main/sub per-particle (via the hashed `mix`)
            // rather than every piece being an identical blend, so the
            // confetti reads as genuinely multi-colored.
            context.opacity = 0.75
            context.fill(Path(pieceRect), with: .color(tint))

        case .rain:
            // Thin, fast, near-vertical streaks — deliberately low-opacity
            // and low-contrast so it reads as mood/texture on the banner
            // rather than obscuring the name/avatar sitting on top of it.
            let fallSpeed = 0.9 + particle.hash(2) * 0.4
            let startX = particle.hash(3) * w
            let slant = -6.0
            let length = 16.0
            let progress = (time * fallSpeed + particle.hash(4)).truncatingRemainder(dividingBy: 1.0)
            let y = progress * (h + length) - length
            guard y > -length, y < h else { return }
            var path = Path()
            path.move(to: point(startX, y))
            path.addLine(to: point(startX + slant, y + length))
            context.stroke(path, with: .color(tint.opacity(0.25)), style: StrokeStyle(lineWidth: 1, lineCap: .round))

        case .waveform:
            // Bars along the bottom edge, each rising and falling on its own
            // frequency. Two summed sines per bar rather than one, because a
            // single sine makes every bar sweep in an obvious wave — the two
            // beating against each other is what reads as audio.
            let barCount = 26.0
            let index = floor(particle.hash(2) * barCount)
            let barWidth = w / barCount
            let x = index * barWidth
            let speedA = 1.6 + particle.hash(3) * 1.8
            let speedB = 2.7 + particle.hash(4) * 2.2
            let phase = particle.hash(5) * .pi * 2
            let level = (sin(time * speedA + phase) + sin(time * speedB + phase * 1.7)) / 4 + 0.5
            let barHeight = max(2.0, level * h * 0.38)
            let barRect = CGRect(
                x: CGFloat(x + barWidth * 0.2), y: CGFloat(h - barHeight),
                width: CGFloat(barWidth * 0.6), height: CGFloat(barHeight)
            )
            context.opacity = 0.32
            context.fill(Path(roundedRect: barRect, cornerRadius: CGFloat(barWidth * 0.3)), with: .color(tint))

        case .starfield:
            // Fixed points that twinkle, with a slow horizontal drift so the
            // field never looks pinned to the banner. Sizes vary enough to
            // suggest depth without anything actually moving in Z.
            let baseX = particle.hash(2)
            let y = particle.hash(3) * h
            let drift = (time * 0.012 + baseX).truncatingRemainder(dividingBy: 1.0)
            let x = drift * w
            let phase = particle.hash(4) * .pi * 2
            let twinkle = (sin(time * 1.8 + phase) + 1) / 2
            let radius = 0.6 + particle.hash(5) * 1.1
            context.opacity = 0.2 + twinkle * 0.55
            context.fill(
                Path(ellipseIn: CGRect(x: CGFloat(x - radius), y: CGFloat(y - radius),
                                       width: CGFloat(radius * 2), height: CGFloat(radius * 2))),
                with: .color(tint.mixed(with: .white, amount: 0.4))
            )

        case .bokeh:
            // Large, soft, slow circles — the one effect meant to be felt
            // rather than noticed. Kept well under half opacity and heavily
            // blurred so the name and avatar sitting on top stay readable,
            // which is the constraint every banner effect here works within.
            let driftSpeed = 0.02 + particle.hash(2) * 0.03
            let baseY = particle.hash(3)
            let x = ((time * driftSpeed + particle.hash(4)).truncatingRemainder(dividingBy: 1.2) / 1.2) * (w + 60) - 30
            let y = (baseY + sin(time * 0.15 + particle.hash(5) * 6) * 0.06) * h
            let radius = 8.0 + particle.hash(6) * 16
            let breathe = (sin(time * 0.4 + particle.hash(7) * 6) + 1) / 2
            context.drawLayer { layer in
                layer.opacity = 0.10 + breathe * 0.12
                layer.addFilter(.blur(radius: 6))
                layer.fill(
                    Path(ellipseIn: CGRect(x: CGFloat(x - radius), y: CGFloat(y - radius),
                                           width: CGFloat(radius * 2), height: CGFloat(radius * 2))),
                    with: .color(tint)
                )
            }

        case .snowfall:
            // The banner-wide counterpart to the avatar decoration of the same
            // name, at a larger scale and lower contrast so it behaves as
            // background texture rather than competing with the profile itself.
            let fallSpeed = 0.1 + particle.hash(2) * 0.1
            let startX = particle.hash(3)
            let sway = 0.02 + particle.hash(4) * 0.03
            let phase = particle.hash(5) * .pi * 2
            let progress = (time * fallSpeed + particle.hash(6)).truncatingRemainder(dividingBy: 1.0)
            let x = (startX + sin(time * 0.6 + phase) * sway).truncatingRemainder(dividingBy: 1) * w
            let y = progress * (h + 12) - 6
            guard y > -6, y < h + 6 else { return }
            let radius = 1.0 + particle.hash(7) * 1.3
            context.opacity = 0.45
            context.fill(
                Path(ellipseIn: CGRect(x: CGFloat(x - radius), y: CGFloat(y - radius),
                                       width: CGFloat(radius * 2), height: CGFloat(radius * 2))),
                with: .color(tint.mixed(with: .white, amount: 0.55))
            )

        case .pulse:
            // Rings expanding from a fixed origin per particle and fading as
            // they grow, like something reacting to a beat. Stroke width thins
            // with the expansion so a ring dissipates rather than simply
            // vanishing at full size.
            let originX = particle.hash(2) * w
            let originY = particle.hash(3) * h
            let period = 2.2 + particle.hash(4) * 1.6
            let progress = (time + particle.hash(5) * period).truncatingRemainder(dividingBy: period) / period
            let radius = progress * min(w, h) * 0.45
            guard radius > 1 else { return }
            context.opacity = 0.35 * (1 - progress)
            context.stroke(
                Path(ellipseIn: CGRect(x: CGFloat(originX - radius), y: CGFloat(originY - radius),
                                       width: CGFloat(radius * 2), height: CGFloat(radius * 2))),
                with: .color(tint),
                lineWidth: CGFloat(max(0.4, 1.6 * (1 - progress)))
            )
        }
    }

    /// Aurora is fundamentally different in shape from every other effect
    /// (a few large soft wave bands, not many small particles), so it gets
    /// its own draw pass instead of being shoehorned into the per-particle
    /// switch above. Same `Double`-math-until-CGPoint discipline as `draw`.
    private func drawAurora(in context: inout GraphicsContext, size: CGSize, time: Double) {
        let w = Double(size.width), h = Double(size.height)
        let bands: [(color: Color, speed: Double, phase: Double, yBase: Double, amplitude: Double)] = [
            (mainTint, 0.25, 0, 0.35, 0.14),
            (subTint, 0.18, 2.1, 0.55, 0.18),
            (mainTint.mixed(with: subTint, amount: 0.5), 0.32, 4.4, 0.45, 0.1),
        ]
        for band in bands {
            var path = Path()
            let steps = 24
            path.move(to: CGPoint(x: 0, y: CGFloat(h)))
            for i in 0...steps {
                let fraction = Double(i) / Double(steps)
                let x = fraction * w
                let wave = sin(fraction * .pi * 2.4 + time * band.speed + band.phase)
                let y = (band.yBase + wave * band.amplitude) * h
                path.addLine(to: CGPoint(x: CGFloat(x), y: CGFloat(y)))
            }
            path.addLine(to: CGPoint(x: CGFloat(w), y: CGFloat(h)))
            path.closeSubpath()
            // Isolated layer so each band's blur doesn't compound onto the
            // next — same reasoning as the fireflies/embers avatar
            // decorations (`GraphicsContext.addFilter` stacks otherwise).
            context.drawLayer { layer in
                layer.opacity = 0.28
                layer.addFilter(.blur(radius: 14))
                layer.fill(path, with: .color(band.color))
            }
        }
    }
}

/// A row of tappable effect-style previews, mirroring `AvatarFramePickerView`/
/// `AvatarDecorationPickerView` — previews on a small banner-shaped swatch
/// instead of a circle, since the effect is meant for that shape.
struct ProfileEffectPickerView: View {
    let mainTint: Color
    let subTint: Color
    @Binding var selected: ProfileEffectStyle

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 2)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(ProfileEffectStyle.allCases) { style in
                Button {
                    withAnimation(LumiMotion.snap) {
                        selected = style
                    }
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            LinearGradient(colors: [mainTint, subTint], startPoint: .topLeading, endPoint: .bottomTrailing)
                            ProfileEffectOverlay(style: style, mainTint: mainTint, subTint: subTint)
                        }
                        .frame(height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(selected == style ? mainTint : .white.opacity(0.2), lineWidth: selected == style ? 2 : 1)
                        )

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
