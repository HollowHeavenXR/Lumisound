import SwiftUI

// MARK: - Avatar decoration styles
//
// Discord-style "Avatar Decoration": a small looping animation overlaid ON
// TOP of the avatar image itself — distinct from `AvatarFrameStyle`, which
// draws AROUND the avatar's outer edge. Like that type, this is purely
// cosmetic, purely client-rendered (a procedural particle system driven by
// `TimelineView(.animation(minimumInterval: LumiMotion.frame))` + `Canvas`, no image/Lottie assets, no
// server-stored pixels) and always tinted from the profile's own main/sub
// accent colors rather than a fixed palette, so a decoration always matches
// the rest of the profile. Validated server-side against this exact set
// (`_VALID_AVATAR_DECORATIONS` in main.py) so a malformed value can never
// reach the client — keep this list in sync if it ever changes.
enum AvatarDecorationStyle: String, CaseIterable, Identifiable {
    case none, sparkles, fireflies, petals, snowfall, embers
    // Second wave, built on the same stateless particle model: every position
    // is a pure function of the clock and the particle's seed, so these cost no
    // stored state and animate identically no matter when they appear.
    case bubbles, orbits, rainfall, dust, notes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:      return "None"
        case .sparkles:  return "Sparkles"
        case .fireflies: return "Fireflies"
        case .petals:    return "Petals"
        case .snowfall:  return "Snowfall"
        case .embers:    return "Embers"
        case .bubbles:   return "Bubbles"
        case .orbits:    return "Orbits"
        case .rainfall:  return "Rain"
        case .dust:      return "Dust"
        case .notes:     return "Notes"
        }
    }

    static func from(_ raw: String?) -> AvatarDecorationStyle {
        AvatarDecorationStyle(rawValue: raw ?? "none") ?? .none
    }
}

/// One procedurally-animated particle — a deterministic function of `time`
/// and the particle's own `seed`, not a stored/mutated position. This is
/// what lets the whole system be stateless: `AvatarDecorationOverlay`/
/// `ProfileEffectOverlay` never own a `[Particle]` array or a per-frame
/// mutation pass, just a pure `position(at:)` each draw call evaluates —
/// simpler, and immune to the state-array-vs-view-identity churn a SwiftUI
/// `TimelineView` redrawing many times a second would otherwise risk.
private struct DecorationParticle {
    let seed: Double

    /// Cheap, deterministic pseudo-random value in `0..<1` for this
    /// particle, stable across every frame — a fractional-sine hash, not a
    /// real PRNG (none of this needs cryptographic quality, just
    /// "looks different per particle" and "identical every time it's
    /// recomputed for the same seed").
    func hash(_ salt: Double) -> Double {
        let x = sin(seed * 12.9898 + salt * 78.233) * 43758.5453
        return x - floor(x)
    }
}

/// Renders the decorative animation overlaid on top of an avatar of the
/// given `diameter`, clipped to the same circle so it never bleeds past the
/// avatar's own edge. `mainTint`/`subTint` are the profile's own accent
/// colors — every style blends between them (see the "how accent colors
/// mix" ask this exists to answer) rather than using a fixed palette.
struct AvatarDecorationOverlay: View {
    let style: AvatarDecorationStyle
    let diameter: CGFloat
    let mainTint: Color
    let subTint: Color

    private static let particleCount = 10
    private let particles: [DecorationParticle] = (0..<AvatarDecorationOverlay.particleCount).map {
        DecorationParticle(seed: Double($0) + 1)
    }

    var body: some View {
        if style == .none {
            EmptyView()
        } else {
            TimelineView(.animation(minimumInterval: LumiMotion.frame)) { timeline in
                Canvas { context, size in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    for particle in particles {
                        draw(particle, in: &context, size: size, time: time)
                    }
                }
            }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            .allowsHitTesting(false)
        }
    }

    /// All position/size math below is done in plain `Double`, converting to
    /// `CGFloat` only at the exact point a `CGRect`/`CGPoint` is constructed
    /// — `CGFloat` and `Double` are DISTINCT types in Swift (even though
    /// `CGFloat` is 64-bit on every platform this app targets) and cannot be
    /// mixed in arithmetic without an explicit conversion, so keeping one
    /// consistent type through all the intermediate math avoids a wall of
    /// `CGFloat(...)` wrapping on every single operand.
    private func draw(_ particle: DecorationParticle, in context: inout GraphicsContext, size: CGSize, time: Double) {
        let w = Double(size.width), h = Double(size.height)
        // Blends main -> sub per-particle (not just a random pick) so the
        // overlay as a whole reads as a genuine mix of both accent colors
        // rather than a 50/50 speckle of two flat colors.
        let mix = particle.hash(1)
        let tint = mainTint.mixed(with: subTint, amount: mix)

        func rect(x: Double, y: Double, radius: Double) -> CGRect {
            CGRect(x: CGFloat(x - radius), y: CGFloat(y - radius), width: CGFloat(radius * 2), height: CGFloat(radius * 2))
        }

        switch style {
        case .none:
            return

        case .sparkles:
            // Small stars that twinkle in place — fixed position, animated
            // opacity/scale only.
            let x = particle.hash(2) * w
            let y = particle.hash(3) * h
            let phase = particle.hash(4) * .pi * 2
            let twinkle = (sin(time * 2.4 + phase) + 1) / 2
            let radius = 1.0 + twinkle * 1.6
            context.opacity = 0.35 + twinkle * 0.65
            context.fill(Path(ellipseIn: rect(x: x, y: y, radius: radius)), with: .color(tint))

        case .fireflies:
            // Slow circular drift with a soft glow — each firefly orbits its
            // own anchor point at its own radius/speed/phase.
            let anchorX = (0.2 + particle.hash(2) * 0.6) * w
            let anchorY = (0.2 + particle.hash(3) * 0.6) * h
            let orbitRadius = (0.08 + particle.hash(4) * 0.12) * min(w, h)
            let speed = 0.4 + particle.hash(5) * 0.5
            let phase = particle.hash(6) * .pi * 2
            let angle = time * speed + phase
            let x = anchorX + cos(angle) * orbitRadius
            let y = anchorY + sin(angle) * orbitRadius
            let glow = (sin(time * 1.6 + phase) + 1) / 2
            let dot = rect(x: x, y: y, radius: 1.4)
            // `drawLayer` isolates the filter to just this one fill — `addFilter`
            // appends to the context's filter stack rather than replacing it, so
            // without an isolated layer every firefly after the first would
            // compound another `blur(radius: 2)` on top of the last, making later
            // particles progressively (and unintentionally) blurrier.
            context.drawLayer { layer in
                layer.opacity = 0.4 + glow * 0.6
                layer.addFilter(.blur(radius: 2))
                layer.fill(Path(ellipseIn: dot), with: .color(tint))
            }

        case .petals:
            // Drifts diagonally downward with a gentle side-to-side sway,
            // looping back to the top once it exits the bottom — a plain
            // `.truncatingRemainder` loop on a time-scaled fall distance.
            let fallSpeed = 0.12 + particle.hash(2) * 0.08
            let startX = particle.hash(3)
            let swayAmount = 0.08 + particle.hash(4) * 0.06
            let swaySpeed = 0.6 + particle.hash(5) * 0.5
            let phase = particle.hash(6) * .pi * 2
            let fallProgress = (time * fallSpeed + particle.hash(7)).truncatingRemainder(dividingBy: 1.2) / 1.2
            let x = (startX + sin(time * swaySpeed + phase) * swayAmount).truncatingRemainder(dividingBy: 1) * w
            let y = fallProgress * h * 1.3 - h * 0.15
            guard y > -6, y < h + 6 else { return }
            let petalSize = 3.2
            let petalRect = CGRect(
                x: CGFloat(x - petalSize / 2), y: CGFloat(y - petalSize / 2),
                width: CGFloat(petalSize), height: CGFloat(petalSize * 1.5)
            )
            context.opacity = 0.55
            context.fill(Path(ellipseIn: petalRect), with: .color(tint))

        case .snowfall:
            // Same fall-and-loop shape as petals, but faster, smaller,
            // straighter, and colder-toned (blended toward white).
            let fallSpeed = 0.22 + particle.hash(2) * 0.15
            let startX = particle.hash(3)
            let swayAmount = 0.03 + particle.hash(4) * 0.03
            let phase = particle.hash(5) * .pi * 2
            let fallProgress = (time * fallSpeed + particle.hash(6)).truncatingRemainder(dividingBy: 1.0)
            let x = (startX + sin(time * 0.8 + phase) * swayAmount).truncatingRemainder(dividingBy: 1) * w
            let y = fallProgress * h * 1.2 - h * 0.1
            guard y > -4, y < h + 4 else { return }
            let flakeColor = tint.mixed(with: .white, amount: 0.6)
            context.opacity = 0.7
            context.fill(Path(ellipseIn: rect(x: x, y: y, radius: 1.3)), with: .color(flakeColor))

        case .embers:
            // Rises upward instead of falling, fading out as it nears the
            // top — the visual inverse of snowfall/petals, warm-toned.
            let riseSpeed = 0.18 + particle.hash(2) * 0.14
            let startX = particle.hash(3)
            let swayAmount = 0.05 + particle.hash(4) * 0.05
            let phase = particle.hash(5) * .pi * 2
            let riseProgress = (time * riseSpeed + particle.hash(6)).truncatingRemainder(dividingBy: 1.0)
            let x = (startX + sin(time * 1.1 + phase) * swayAmount).truncatingRemainder(dividingBy: 1) * w
            let y = h - riseProgress * h * 1.2 + h * 0.1
            guard y > -4, y < h + 4 else { return }
            let dot = rect(x: x, y: y, radius: 1.2)
            let emberColor = tint.mixed(with: .orange, amount: 0.5)
            // Fades out over the last third of its rise, matching a real
            // spark cooling/dispersing rather than just vanishing at a hard cutoff.
            let fadeOut = riseProgress > 0.66 ? max(0, 1 - (riseProgress - 0.66) / 0.34) : 1
            // Isolated layer — same accumulating-filter reasoning as fireflies above.
            context.drawLayer { layer in
                layer.opacity = 0.8 * fadeOut
                layer.addFilter(.blur(radius: 1))
                layer.fill(Path(ellipseIn: dot), with: .color(emberColor))
            }

        case .bubbles:
            // Rises like embers but reads as liquid rather than fire: stroked
            // outlines instead of filled dots, a wider wobble, and a size that
            // grows on the way up the way a real bubble expands as pressure drops.
            let riseSpeed = 0.14 + particle.hash(2) * 0.12
            let startX = particle.hash(3)
            let wobble = 0.04 + particle.hash(4) * 0.05
            let phase = particle.hash(5) * .pi * 2
            let progress = (time * riseSpeed + particle.hash(6)).truncatingRemainder(dividingBy: 1.0)
            let x = (startX + sin(time * 1.4 + phase) * wobble).truncatingRemainder(dividingBy: 1) * w
            let y = h - progress * h * 1.15 + h * 0.08
            guard y > -5, y < h + 5 else { return }
            let radius = 1.0 + particle.hash(7) * 1.4 + progress * 0.8
            context.opacity = 0.65 * (1 - progress * 0.5)
            context.stroke(Path(ellipseIn: rect(x: x, y: y, radius: radius)),
                           with: .color(tint), lineWidth: 0.9)

        case .orbits:
            // Everything circles the avatar's centre rather than drifting
            // independently, which gives the overlay a single focal point
            // instead of scattered motion. Alternating direction keeps it from
            // looking like one rigid rotating disc.
            let cx = w / 2, cy = h / 2
            let orbitRadius = (0.18 + particle.hash(2) * 0.28) * min(w, h)
            let speed = 0.5 + particle.hash(3) * 0.7
            let direction: Double = particle.hash(4) > 0.5 ? 1 : -1
            let phase = particle.hash(5) * .pi * 2
            let angle = time * speed * direction + phase
            let x = cx + cos(angle) * orbitRadius
            let y = cy + sin(angle) * orbitRadius * 0.55   // flattened, so it reads as a tilted orbit
            context.opacity = 0.75
            context.fill(Path(ellipseIn: rect(x: x, y: y, radius: 1.1 + particle.hash(6))),
                         with: .color(tint))

        case .rainfall:
            // Short vertical streaks falling fast and straight — drawn as lines
            // rather than dots, since a dot moving quickly reads as a dot, and a
            // streak reads as speed.
            let fallSpeed = 0.5 + particle.hash(2) * 0.4
            let x = particle.hash(3) * w
            let progress = (time * fallSpeed + particle.hash(4)).truncatingRemainder(dividingBy: 1.0)
            let y = progress * h * 1.25 - h * 0.12
            let length = 4.0 + particle.hash(5) * 4
            guard y > -length, y < h + length else { return }
            var streak = Path()
            streak.move(to: CGPoint(x: CGFloat(x), y: CGFloat(y)))
            streak.addLine(to: CGPoint(x: CGFloat(x), y: CGFloat(y + length)))
            context.opacity = 0.5
            context.stroke(streak, with: .color(tint.mixed(with: .white, amount: 0.35)), lineWidth: 0.9)

        case .dust:
            // Barely-moving motes. Two sine terms at unrelated speeds give a
            // wandering path that never repeats on an obvious beat, which is what
            // separates "floating" from "orbiting".
            let baseX = particle.hash(2)
            let baseY = particle.hash(3)
            let driftX = sin(time * (0.15 + particle.hash(4) * 0.2) + particle.hash(5) * 6) * 0.06
            let driftY = cos(time * (0.11 + particle.hash(6) * 0.17) + particle.hash(7) * 6) * 0.06
            let x = (baseX + driftX) * w
            let y = (baseY + driftY) * h
            let shimmer = (sin(time * 0.9 + particle.hash(8) * 6) + 1) / 2
            context.opacity = 0.25 + shimmer * 0.35
            context.fill(Path(ellipseIn: rect(x: x, y: y, radius: 0.9)), with: .color(tint))

        case .notes:
            // Music notes drifting upward — a filled note head with a stem,
            // drawn as paths like everything else here rather than as an SF
            // Symbol. A resolved symbol would have to be sized through a draw
            // rect and tinted through its shading, which is more moving parts
            // than a two-shape glyph needs at seven points across.
            let riseSpeed = 0.1 + particle.hash(2) * 0.09
            let startX = particle.hash(3)
            let sway = 0.05 + particle.hash(4) * 0.05
            let phase = particle.hash(5) * .pi * 2
            let progress = (time * riseSpeed + particle.hash(6)).truncatingRemainder(dividingBy: 1.0)
            let x = (startX + sin(time * 0.9 + phase) * sway).truncatingRemainder(dividingBy: 1) * w
            let y = h - progress * h * 1.15 + h * 0.08
            guard y > -8, y < h + 8 else { return }
            // Fades in at the bottom and out at the top so notes never pop into
            // or out of existence at the edges.
            let edgeFade = min(1, progress / 0.15) * min(1, (1 - progress) / 0.2)
            context.opacity = 0.75 * edgeFade
            // Head: a slightly wide ellipse, tilted the way a drawn note is by
            // making it wider than tall rather than by applying a rotation.
            let headW = 3.4, headH = 2.6
            let headRect = CGRect(x: CGFloat(x - headW / 2), y: CGFloat(y - headH / 2),
                                  width: CGFloat(headW), height: CGFloat(headH))
            context.fill(Path(ellipseIn: headRect), with: .color(tint))
            // Stem: up from the right edge of the head.
            var stem = Path()
            stem.move(to: CGPoint(x: CGFloat(x + headW / 2 - 0.4), y: CGFloat(y)))
            stem.addLine(to: CGPoint(x: CGFloat(x + headW / 2 - 0.4), y: CGFloat(y - 6)))
            context.stroke(stem, with: .color(tint), lineWidth: 0.9)
            // Flag, on roughly half of them, so the field reads as mixed notes
            // rather than one glyph repeated.
            if particle.hash(7) > 0.5 {
                var flag = Path()
                flag.move(to: CGPoint(x: CGFloat(x + headW / 2 - 0.4), y: CGFloat(y - 6)))
                flag.addQuadCurve(to: CGPoint(x: CGFloat(x + headW / 2 + 2), y: CGFloat(y - 3.2)),
                                  control: CGPoint(x: CGFloat(x + headW / 2 + 2.4), y: CGFloat(y - 5.4)))
                context.stroke(flag, with: .color(tint), lineWidth: 0.9)
            }
        }
    }
}

/// A row of tappable decoration-style previews, mirroring
/// `AvatarFramePickerView` exactly.
struct AvatarDecorationPickerView: View {
    let mainTint: Color
    let subTint: Color
    @Binding var selected: AvatarDecorationStyle

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(AvatarDecorationStyle.allCases) { style in
                Button {
                    withAnimation(LumiMotion.snap) {
                        selected = style
                    }
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(mainTint.opacity(0.25))
                                .frame(width: 40, height: 40)
                                .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1))
                            AvatarDecorationOverlay(style: style, diameter: 40, mainTint: mainTint, subTint: subTint)
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
