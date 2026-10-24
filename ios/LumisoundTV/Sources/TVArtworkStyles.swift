import SwiftUI

// MARK: - TVArtworkStyle
//
// A small subset of iOS's 24 Now Playing artwork styles (see
// ios/Lumisound/Sources/Views/NowPlayingStyle.swift), ported to tvOS.
// Most of the originals depend on `Song`/`LibraryManager`/palette
// extraction that don't exist on tvOS's much smaller client; these two were
// picked (per a feasibility survey) as self-contained, non-touch,
// non-AVAudioEngine-dependent — Circuit Pulse used a live extracted palette
// on iOS, simplified here to its own documented fallback colors (cyan/accent)
// since porting the palette extractor for one cosmetic detail isn't worth it.

enum TVArtworkStyle: String, CaseIterable, Identifiable {
    case classic
    case circuitPulse
    case radarSweep
    case chalkboardSketch
    case shadowPuppetSilhouette

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .circuitPulse: return "Circuit Pulse"
        case .radarSweep: return "Radar Sweep"
        case .chalkboardSketch: return "Chalkboard Sketch"
        case .shadowPuppetSilhouette: return "Shadow Puppet"
        }
    }
}

// MARK: - Shared clock / cover helpers (ported from ArtworkEffectsShared.swift)

enum TVArtworkClock {
    static func pingPong(_ date: Date, legDuration: Double) -> Double {
        guard legDuration > 0 else { return 0 }
        let t = date.timeIntervalSinceReferenceDate
        return 0.5 - 0.5 * cos(.pi * t / legDuration)
    }

    static func loop(_ date: Date, cycleDuration: Double) -> Double {
        guard cycleDuration > 0 else { return 0 }
        let t = date.timeIntervalSinceReferenceDate
        return t.truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
    }
}

struct TVFloatModifier: ViewModifier {
    let isPlaying: Bool
    let amount: CGFloat
    let speed: Double

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: !isPlaying)) { timeline in
            let phase = TVArtworkClock.pingPong(timeline.date, legDuration: speed)
            content
                .offset(y: isPlaying ? -amount * phase : 0)
                .animation(.easeOut(duration: 0.4), value: isPlaying)
        }
    }
}

/// The real artwork when available, a themed placeholder otherwise — mirrors
/// `StyleCover` on iOS, sourced from `TVAuthImage` instead of `LibraryManager`.
struct TVStyleCover: View {
    let artworkURL: URL?
    let authToken: String?
    let size: CGFloat
    var cornerRadius: CGFloat = 0

    var body: some View {
        TVAuthImage(url: artworkURL, token: authToken) {
            TVArtPlaceholder(systemImage: "music.note", iconScale: size / 180)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Circuit Pulse (440pt, scaled up from iOS's 300pt original)

struct TVCircuitPulseArtworkView: View {
    let artworkURL: URL?
    let authToken: String?
    let isPlaying: Bool

    private let traceColor = TVPalette.violet.opacity(0.6)
    private let pulseColor = TVPalette.neon

    var body: some View {
        TimelineView(.animation) { timeline in
            let pulseProgress = TVArtworkClock.loop(timeline.date, cycleDuration: 4.5)

            ZStack {
                RoundedRectangle(cornerRadius: 38, style: .continuous)
                    .fill(TVPalette.ground)

                Canvas { context, size in
                    let inset: CGFloat = 50
                    let loop = Path(roundedRect: CGRect(x: inset, y: inset,
                                                         width: size.width - inset * 2,
                                                         height: size.height - inset * 2),
                                     cornerSize: CGSize(width: 14, height: 14))
                    context.stroke(loop, with: .color(traceColor), lineWidth: 2)

                    let branches: [(CGPoint, CGPoint)] = [
                        (CGPoint(x: inset, y: size.height * 0.3), CGPoint(x: inset - 28, y: size.height * 0.3)),
                        (CGPoint(x: size.width - inset, y: size.height * 0.7), CGPoint(x: size.width - inset + 28, y: size.height * 0.7)),
                        (CGPoint(x: size.width * 0.3, y: inset), CGPoint(x: size.width * 0.3, y: inset - 28)),
                        (CGPoint(x: size.width * 0.7, y: size.height - inset), CGPoint(x: size.width * 0.7, y: size.height - inset + 28)),
                    ]
                    for (a, b) in branches {
                        var p = Path()
                        p.move(to: a)
                        p.addLine(to: b)
                        context.stroke(p, with: .color(traceColor), lineWidth: 2)
                        context.fill(Path(ellipseIn: CGRect(x: b.x - 4, y: b.y - 4, width: 8, height: 8)),
                                     with: .color(traceColor))
                    }
                }
                .frame(width: 440, height: 440)

                Circle()
                    .fill(pulseColor)
                    .frame(width: 14, height: 14)
                    .shadow(color: pulseColor, radius: 10)
                    .position(pulsePosition(progress: pulseProgress, in: CGSize(width: 440, height: 440)))

                TVStyleCover(artworkURL: artworkURL, authToken: authToken, size: 280, cornerRadius: 24)
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.22), lineWidth: 1))
                    .shadow(color: .black.opacity(0.55), radius: 24, y: 14)
                    .shadow(color: pulseColor.opacity(0.4), radius: 24)
            }
            .frame(width: 440, height: 440)
        }
        .modifier(TVFloatModifier(isPlaying: isPlaying, amount: 6, speed: 3.8))
    }

    private func pulsePosition(progress: CGFloat, in size: CGSize) -> CGPoint {
        let inset: CGFloat = 50
        let left = inset, right = size.width - inset
        let top = inset, bottom = size.height - inset
        let perimeter = 2 * (right - left) + 2 * (bottom - top)
        let d = progress * perimeter

        if d < (right - left) {
            return CGPoint(x: left + d, y: top)
        } else if d < (right - left) + (bottom - top) {
            return CGPoint(x: right, y: top + (d - (right - left)))
        } else if d < 2 * (right - left) + (bottom - top) {
            return CGPoint(x: right - (d - (right - left) - (bottom - top)), y: bottom)
        } else {
            return CGPoint(x: left, y: bottom - (d - 2 * (right - left) - (bottom - top)))
        }
    }
}

// MARK: - Radar Sweep (440pt, scaled up from iOS's 300pt original)

struct TVRadarSweepArtworkView: View {
    let artworkURL: URL?
    let authToken: String?
    let isPlaying: Bool

    private let contacts: [(angle: Double, radius: CGFloat)] = [
        (angle: 40, radius: 0.55), (angle: 130, radius: 0.8),
        (angle: 210, radius: 0.4), (angle: 300, radius: 0.68),
    ]

    var body: some View {
        TimelineView(.animation) { timeline in
            let sweepAngle = TVArtworkClock.loop(timeline.date, cycleDuration: 3.2) * 360
            let blipPulse = 0.3 + 0.65 * TVArtworkClock.pingPong(timeline.date, legDuration: 1.4)

            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 0.02, green: 0.1, blue: 0.05), .black],
                                          center: .center, startRadius: 14, endRadius: 235))

                ForEach(1..<5, id: \.self) { i in
                    Circle()
                        .stroke(.green.opacity(0.28), lineWidth: 1)
                        .frame(width: CGFloat(i) * 103, height: CGFloat(i) * 103)
                }

                TVSweepWedge(spanDegrees: 45)
                    .fill(
                        AngularGradient(
                            colors: [.green.opacity(0), .green.opacity(0.6)],
                            center: .center,
                            startAngle: .degrees(-45), endAngle: .degrees(0)
                        )
                    )
                    .frame(width: 411, height: 411)
                    .rotationEffect(.degrees(sweepAngle))

                ForEach(Array(contacts.enumerated()), id: \.offset) { _, contact in
                    Circle()
                        .fill(.green)
                        .frame(width: 9, height: 9)
                        .shadow(color: .green, radius: 6)
                        .opacity(blipPulse)
                        .offset(
                            x: cos(contact.angle * .pi / 180) * contact.radius * 205,
                            y: sin(contact.angle * .pi / 180) * contact.radius * 205
                        )
                }

                TVStyleCover(artworkURL: artworkURL, authToken: authToken, size: 220, cornerRadius: 110)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.green.opacity(0.6), lineWidth: 2))
                    .shadow(color: .green.opacity(0.5), radius: 24)
            }
            .frame(width: 440, height: 440)
            .clipShape(Circle())
            .overlay(Circle().stroke(.green.opacity(0.3), lineWidth: 1))
        }
        .modifier(TVFloatModifier(isPlaying: isPlaying, amount: 6, speed: 4.0))
    }
}

// MARK: - Chalkboard Sketch (440pt, scaled up from iOS's 300pt original)
//
// Ported from ios/Lumisound/Sources/Views/ChalkboardSketchArtworkView.swift —
// no Song/LibraryManager/palette dependency beyond the cover image itself, so
// this one needed no simplification, just its own `TVStyleCover` +
// re-implemented `FilmGrainOverlay`/`SeededRandom` (ArtworkEffectsShared.swift
// isn't part of this target — same reasoning as `TVArtworkClock`/
// `TVFloatModifier` above).

/// Tiny deterministic xorshift PRNG — ported from `SeededRandom` in
/// ArtworkEffectsShared.swift. Deterministic (fixed seed) so the grain
/// pattern doesn't re-roll every redraw.
private struct TVSeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xdead_beef : seed
    }

    mutating func nextDouble() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
}

private struct TVFilmGrainOverlay: View {
    var body: some View {
        Canvas { context, size in
            var generator = TVSeededRandom(seed: 1_337)
            let dotCount = Int((size.width * size.height) / 14)
            for _ in 0..<dotCount {
                let x = generator.nextDouble() * size.width
                let y = generator.nextDouble() * size.height
                let alpha = 0.05 + generator.nextDouble() * 0.18
                let dotSize = generator.nextDouble() < 0.5 ? 0.6 : 1.1
                let rect = CGRect(x: x, y: y, width: dotSize, height: dotSize)
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(alpha)))
            }
        }
        .drawingGroup()
    }
}

struct TVChalkboardSketchArtworkView: View {
    let artworkURL: URL?
    let authToken: String?
    let isPlaying: Bool

    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { timeline in
            let trimEnd = TVArtworkClock.pingPong(timeline.date, legDuration: 3.4)

            ZStack {
                RoundedRectangle(cornerRadius: 35, style: .continuous)
                    .fill(Color(red: 0.09, green: 0.13, blue: 0.1))
                    .overlay(TVFilmGrainOverlay().opacity(0.5))

                TVStyleCover(artworkURL: artworkURL, authToken: authToken, size: 308, cornerRadius: 20)
                    .saturation(0.35)
                    .contrast(1.05)
                    .clipShape(shape)
                    .overlay(shape.stroke(.white.opacity(0.5), lineWidth: 3))
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 8)

                shape
                    .trim(from: 0, to: trimEnd)
                    .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [1, 3]))
                    .frame(width: 328, height: 328)
            }
            .frame(width: 440, height: 440)
            .clipShape(RoundedRectangle(cornerRadius: 35, style: .continuous))
            .drawingGroup()
        }
        .modifier(TVFloatModifier(isPlaying: isPlaying, amount: 6, speed: 3.8))
    }
}

// MARK: - Shadow Puppet Silhouette (440pt, scaled up from iOS's 300pt original)
//
// Ported from ios/Lumisound/Sources/Views/ShadowPuppetSilhouetteArtworkView.swift
// — likewise no Song/LibraryManager/palette dependency beyond the cover image.

struct TVShadowPuppetSilhouetteArtworkView: View {
    let artworkURL: URL?
    let authToken: String?
    let isPlaying: Bool

    private let shape = RoundedRectangle(cornerRadius: 29, style: .continuous)

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { timeline in
            let sway = -4 + 8 * TVArtworkClock.pingPong(timeline.date, legDuration: 2.8)

            ZStack {
                RadialGradient(
                    colors: [Color(red: 0.55, green: 0.32, blue: 0.08), Color(red: 0.05, green: 0.02, blue: 0.0)],
                    center: UnitPoint(x: 0.5, y: 0.15), startRadius: 14, endRadius: 335
                )

                // The "rod" the puppet sways from.
                Rectangle()
                    .fill(.black.opacity(0.6))
                    .frame(width: 4, height: 58)
                    .offset(y: -235)

                TVStyleCover(artworkURL: artworkURL, authToken: authToken, size: 293, cornerRadius: 29)
                    .colorMultiply(.black)
                    .brightness(-0.05)
                    .clipShape(shape)
                    .overlay(shape.fill(.black.opacity(0.35)))
                    .overlay(shape.stroke(.black.opacity(0.6), lineWidth: 2))
                    .offset(y: -44)
                    .rotationEffect(.degrees(sway), anchor: UnitPoint(x: 0.5, y: -0.15))
            }
            .frame(width: 440, height: 440)
            .clipShape(RoundedRectangle(cornerRadius: 41, style: .continuous))
            .drawingGroup()
        }
    }
}

/// An explicit pie-slice shape spanning `spanDegrees`, from the shape's own
/// 0° back to `-spanDegrees` — center point, out along one edge, arc across,
/// back to center.
private struct TVSweepWedge: Shape {
    let spanDegrees: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: radius,
                    startAngle: .degrees(-spanDegrees), endAngle: .degrees(0),
                    clockwise: false)
        path.closeSubpath()
        return path
    }
}
