import SwiftUI

// MARK: - Lumisound artwork styles (2026-11)
//
// Every Now Playing artwork style, redrawn with its own idea. They share
// `StyleStage`: the artwork's two-colour palette, a wall-clock time `t`
// from a TimelineView capped at 60 fps (paused when not playing or off
// screen) and the 300×300 stage. Persisted style ids are unchanged, so a
// saved choice keeps working; the names describe the new designs.

/// Palette + clock + stage shared by every style.
struct StyleStage<Content: View>: View {
    let song: Song?
    let isPlaying: Bool
    var size: CGFloat = 300
    @ViewBuilder let content: (_ t: Double, _ c1: Color, _ c2: Color) -> Content
    @State private var palette: ArtworkPalette?

    var body: some View {
        TimelineView(.animation(minimumInterval: LumiMotion.frame, paused: !isPlaying)) { tl in
            content(tl.date.timeIntervalSinceReferenceDate,
                    palette?.primary ?? AppTheme.dynamicAccent,
                    palette?.secondary ?? AppTheme.accentSoft)
        }
        .frame(width: size, height: size)
        .task(id: song?.id) { palette = await ArtworkPaletteLoader.palette(for: song) }
        .animation(LumiMotion.fade(1.0), value: palette)
    }
}

/// The cover with the house finish: hairline rim and a soft drop shadow.
private struct Cover: View {
    let song: Song?
    var size: CGFloat = 190
    var radius: CGFloat = 20
    var glow: Color? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        StyleCover(song: song, size: size, cornerRadius: radius)
            .clipShape(shape)
            .overlay(shape.stroke(.white.opacity(0.2), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
            .shadow(color: (glow ?? .clear).opacity(0.45), radius: 24)
    }
}

private func osc(_ t: Double, _ period: Double, _ phase: Double = 0) -> Double {
    0.5 + 0.5 * sin(t * 2 * .pi / period + phase)
}

// MARK: Prism Bloom (kaleidoscopeBloom)

/// Twelve prism shards of the cover fan out like petals and close again with a
/// slow breath; each shard catches a different hue at its edge.
struct KaleidoscopeBloomArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    var body: some View {
        StyleStage(song: song, isPlaying: isPlaying) { t, c1, c2 in
            let open = osc(t, 7)
            ZStack {
                ForEach(0..<12, id: \.self) { i in
                    StyleCover(song: song, size: 120)
                        .clipShape(PrismShard())
                        .overlay(PrismShard().stroke(Color(hue: Double(i) / 12, saturation: 0.7, brightness: 1).opacity(0.7), lineWidth: 1))
                        .opacity(0.5)
                        .offset(y: -70 - 30 * open)
                        .rotationEffect(.degrees(Double(i) * 30 + t * 6))
                }
                RadialGradient(colors: [c1.opacity(0.5), .clear], center: .center, startRadius: 40, endRadius: 150)
                Cover(song: song, size: 170, radius: 85, glow: c2)
            }
            .drawingGroup()
        }
    }
}

private struct PrismShard: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX * 0.72, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX * 0.28, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: Night Drive (synthwaveHorizon)

/// The cover is the setting sun over a road; lane dashes rush toward you and
/// a skyline of the artwork's colours stands on the horizon.
struct SynthwaveHorizonArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    var body: some View {
        StyleStage(song: song, isPlaying: isPlaying) { t, c1, c2 in
            ZStack {
                LinearGradient(colors: [Color(red: 0.08, green: 0.02, blue: 0.16), c1.opacity(0.6), Color(red: 0.04, green: 0.0, blue: 0.08)], startPoint: .top, endPoint: .bottom)
                Cover(song: song, size: 130, radius: 65, glow: c2).offset(y: -40)
                Canvas { ctx, size in
                    let horizon = size.height * 0.58
                    // Skyline
                    var x: CGFloat = 0
                    var k = 0
                    while x < size.width {
                        let w = CGFloat(14 + (k * 37 % 19))
                        let h = CGFloat(18 + (k * 53 % 40))
                        ctx.fill(Path(CGRect(x: x, y: horizon - h, width: w - 2, height: h)), with: .color(c2.opacity(0.35)))
                        x += w
                        k += 1
                    }
                    ctx.fill(Path(CGRect(x: 0, y: horizon, width: size.width, height: size.height - horizon)), with: .color(.black.opacity(0.55)))
                    // Road edges
                    var road = Path()
                    road.move(to: CGPoint(x: size.width * 0.47, y: horizon))
                    road.addLine(to: CGPoint(x: 0, y: size.height))
                    road.move(to: CGPoint(x: size.width * 0.53, y: horizon))
                    road.addLine(to: CGPoint(x: size.width, y: size.height))
                    ctx.stroke(road, with: .color(c1), lineWidth: 2)
                    // Lane dashes: perspective, scrolling toward the viewer.
                    for i in 0..<8 {
                        let z = (Double(i) + (t * 1.4).truncatingRemainder(dividingBy: 1)) / 8
                        let y = horizon + CGFloat(z * z) * (size.height - horizon)
                        let len = CGFloat(2 + 16 * z * z)
                        ctx.fill(Path(CGRect(x: size.width / 2 - 1.5 - CGFloat(z) * 2, y: y, width: 3 + CGFloat(z) * 4, height: len)), with: .color(.white.opacity(0.3 + 0.6 * z)))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }
}

// MARK: Bar Window (equalizerCutout)

/// The cover seen through fourteen moving bars, like a VU meter made of the art.
struct EqualizerCutoutArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    var body: some View {
        StyleStage(song: song, isPlaying: isPlaying) { t, c1, _ in
            ZStack {
                Cover(song: song, size: 230, radius: 24).opacity(0.18).blur(radius: 6)
                StyleCover(song: song, size: 230)
                    .mask(
                        HStack(alignment: .bottom, spacing: 4) {
                            ForEach(0..<14, id: \.self) { i in
                                let h = 0.25 + 0.75 * osc(t, 0.9 + Double(i % 5) * 0.23, Double(i) * 1.3) * osc(t, 3.1, Double(i))
                                RoundedRectangle(cornerRadius: 3).frame(height: 230 * h)
                            }
                        }
                        .frame(width: 230, height: 230, alignment: .bottom)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: c1.opacity(0.5), radius: 20)
            }
        }
    }
}

// MARK: Lava Lens (liquidBlobFrame)

/// The cover inside a slowly morphing lava-lamp blob, ringed by its own glow.
struct LiquidBlobFrameArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    var body: some View {
        StyleStage(song: song, isPlaying: isPlaying) { t, c1, c2 in
            ZStack {
                LavaBlob(t: t, amp: 0.09).fill(LinearGradient(colors: [c1, c2], startPoint: .top, endPoint: .bottom)).blur(radius: 24).opacity(0.7).scaleEffect(1.12)
                StyleCover(song: song, size: 240)
                    .clipShape(LavaBlob(t: t + 3, amp: 0.06))
                    .overlay(LavaBlob(t: t + 3, amp: 0.06).stroke(.white.opacity(0.35), lineWidth: 1.5))
            }
            .frame(width: 250, height: 250)
        }
    }
}

private struct LavaBlob: Shape {
    let t: Double
    let amp: Double
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        let base = min(r.width, r.height) / 2 * (1 - amp)
        var p = Path()
        for i in 0...96 {
            let a = Double(i) / 96 * 2 * .pi
            let rr = base * (1 + amp * sin(3 * a + t * 0.9) + amp * 0.6 * sin(5 * a - t * 1.3) + amp * 0.4 * cos(2 * a + t * 0.5))
            let pt = CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

// MARK: Paper Crane (origamiFoldReveal)

/// The cover as four creased panels folding in and out in sequence, like a
/// paper crane breathing.
struct OrigamiFoldRevealArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    var body: some View {
        StyleStage(song: song, isPlaying: isPlaying) { t, c1, _ in
            let s: CGFloat = 220
            ZStack {
                ForEach(0..<4, id: \.self) { i in
                    let fold = osc(t, 4.5, Double(i) * .pi / 2) * 28
                    let axis: (CGFloat, CGFloat, CGFloat) = i % 2 == 0 ? (1, 0, 0) : (0, 1, 0)
                    StyleCover(song: song, size: s)
                        .frame(width: s, height: s)
                        .mask(Rectangle().frame(width: s / 2, height: s / 2).offset(x: (i == 1 || i == 3 ? 1 : -1) * s / 4, y: (i >= 2 ? 1 : -1) * s / 4))
                        .rotation3DEffect(.degrees(fold * (i < 2 ? 1 : -1)), axis: axis, anchor: .center, perspective: 0.6)
                        .brightness(-fold / 300)
                }
                Rectangle().stroke(.white.opacity(0.25), lineWidth: 0.5).frame(width: s, height: 0.5)
                Rectangle().stroke(.white.opacity(0.25), lineWidth: 0.5).frame(width: 0.5, height: s)
            }
            .shadow(color: c1.opacity(0.4), radius: 22)
        }
    }
}

// MARK: Tile Pulse (mosaicShatter)

/// The cover as a 6×6 mosaic; a wave lifts the tiles diagonally across it.
struct MosaicShatterArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    var body: some View {
        StyleStage(song: song, isPlaying: isPlaying) { t, c1, _ in
            let n = 6
            let s: CGFloat = 228
            let cell = s / CGFloat(n)
            ZStack {
                ForEach(0..<(n * n), id: \.self) { k in
                    let (r, c) = (k / n, k % n)
                    let wave = osc(t, 3.2, -Double(r + c) * 0.45)
                    StyleCover(song: song, size: s)
                        .frame(width: s, height: s)
                        .mask(Rectangle().frame(width: cell - 2, height: cell - 2)
                            .offset(x: (CGFloat(c) + 0.5) * cell - s / 2, y: (CGFloat(r) + 0.5) * cell - s / 2))
                        .scaleEffect(1 + 0.04 * wave)
                        .offset(y: -6 * wave)
                        .brightness(0.08 * wave)
                }
            }
            .shadow(color: c1.opacity(0.45), radius: 20)
        }
    }
}

// MARK: Signal Board (circuitPulse)

/// The cover mounted on a circuit board; light pulses run along the traces
/// into the art.
struct CircuitPulseArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    var body: some View {
        StyleStage(song: song, isPlaying: isPlaying) { t, c1, c2 in
            ZStack {
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    for i in 0..<16 {
                        let a = Double(i) / 16 * 2 * .pi
                        let bend = CGFloat(30 + (i * 13 % 25))
                        let start = CGPoint(x: c.x + cos(a) * 150, y: c.y + sin(a) * 150)
                        let elbow = CGPoint(x: c.x + cos(a) * (95 + bend * 0.3), y: start.y)
                        let end = CGPoint(x: c.x + cos(a) * 90, y: c.y + sin(a) * 90)
                        var p = Path()
                        p.move(to: start)
                        p.addLine(to: elbow)
                        p.addLine(to: end)
                        ctx.stroke(p, with: .color(c2.opacity(0.25)), lineWidth: 1.5)
                        // Pulse
                        let f = (t * 0.6 + Double(i) * 0.37).truncatingRemainder(dividingBy: 1)
                        let pt = f < 0.5
                            ? CGPoint(x: start.x + (elbow.x - start.x) * f * 2, y: start.y)
                            : CGPoint(x: elbow.x + (end.x - elbow.x) * (f - 0.5) * 2, y: elbow.y + (end.y - elbow.y) * (f - 0.5) * 2)
                        ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 2.5, y: pt.y - 2.5, width: 5, height: 5)), with: .color(c1))
                        ctx.fill(Path(ellipseIn: CGRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6)), with: .color(c2.opacity(0.5)))
                    }
                }
                Cover(song: song, size: 168, radius: 14, glow: c1)
            }
        }
    }
}

// MARK: Sonar (radarSweep)

/// Sonar pings ripple out from the cover while a sweep beam circles it.
struct RadarSweepArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    var body: some View {
        StyleStage(song: song, isPlaying: isPlaying) { t, c1, _ in
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let f = (t / 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Circle().stroke(c1.opacity(1 - f), lineWidth: 2).frame(width: 160 + 140 * f, height: 160 + 140 * f)
                }
                AngularGradient(colors: [c1.opacity(0.55), .clear, .clear, .clear], center: .center, angle: .degrees(t * 90))
                    .clipShape(Circle())
                    .frame(width: 300, height: 300)
                    .blendMode(.plusLighter)
                Cover(song: song, size: 160, radius: 80, glow: c1)
            }
        }
    }
}

// MARK: Glitter Ball (discoMirrorBall)

/// A round cover faceted like a mirror ball, with glints sliding across the facets.
struct DiscoMirrorBallArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    var body: some View {
        StyleStage(song: song, isPlaying: isPlaying) { t, c1, c2 in
            ZStack {
                Cover(song: song, size: 220, radius: 110, glow: c2)
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    let r: CGFloat = 110
                    let step: CGFloat = 14
                    var y = c.y - r
                    while y < c.y + r {
                        var x = c.x - r
                        while x < c.x + r {
                            let dx = x + step / 2 - c.x, dy = y + step / 2 - c.y
                            if dx * dx + dy * dy < r * r {
                                ctx.stroke(Path(CGRect(x: x, y: y, width: step, height: step)), with: .color(.white.opacity(0.18)), lineWidth: 0.5)
                                let glint = sin(Double(x) * 0.07 + Double(y) * 0.05 - t * 2.4)
                                if glint > 0.93 {
                                    ctx.fill(Path(CGRect(x: x + 1, y: y + 1, width: step - 2, height: step - 2)), with: .color(.white.opacity((glint - 0.93) * 10)))
                                }
                            }
                            x += step
                        }
                        y += step
                    }
                }
                .frame(width: 240, height: 240)
                .rotationEffect(.degrees(t * 4))
                .mask(Circle().frame(width: 220, height: 220))
            }
            .background(RadialGradient(colors: [c1.opacity(0.35), .clear], center: .center, startRadius: 100, endRadius: 150))
        }
    }
}

// MARK: Frost Bloom (frostedIceCrystal)

/// Frost crystals grow in from the corners on a frosted rim, then melt back.
struct FrostedIceCrystalArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    var body: some View {
        StyleStage(song: song, isPlaying: isPlaying) { t, _, _ in
            let grow = osc(t, 9)
            ZStack {
                Cover(song: song, size: 230, radius: 26, glow: .cyan)
                Canvas { ctx, size in
                    let corners = [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)]
                    for (k, c) in corners.enumerated() {
                        let toward = atan2(size.height / 2 - c.y, size.width / 2 - c.x)
                        for b in 0..<5 {
                            let a = toward + Double(b - 2) * 0.32
                            let len = CGFloat(30 + 40 * grow) * CGFloat(1 - abs(Double(b - 2)) * 0.18)
                            let tip = CGPoint(x: c.x + cos(a) * len, y: c.y + sin(a) * len)
                            var p = Path()
                            p.move(to: c)
                            p.addLine(to: tip)
                            for s in 1..<4 {
                                let f = CGFloat(s) / 4
                                let mid = CGPoint(x: c.x + (tip.x - c.x) * f, y: c.y + (tip.y - c.y) * f)
                                for side in [-1.0, 1.0] {
                                    let sa = a + side * 0.9
                                    p.move(to: mid)
                                    p.addLine(to: CGPoint(x: mid.x + cos(sa) * len * 0.22 * (1 - f), y: mid.y + sin(sa) * len * 0.22 * (1 - f)))
                                }
                            }
                            ctx.stroke(p, with: .color(.white.opacity(0.75 - Double(k) * 0.05)), lineWidth: 1)
                        }
                    }
                }
                .frame(width: 230, height: 230)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white.opacity(0.5), lineWidth: 6).blur(radius: 3).frame(width: 230, height: 230)
            }
        }
    }
}

// MARK: Glow Tide (bioluminescentTide)

/// The cover floats over a dark sea whose waves glow, with plankton drifting up.
struct BioluminescentTideArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    var body: some View {
        StyleStage(song: song, isPlaying: isPlaying) { t, c1, _ in
            ZStack {
                Color(red: 0.01, green: 0.04, blue: 0.08)
                Canvas { ctx, size in
                    for layer in 0..<3 {
                        var p = Path()
                        let base = size.height * (0.66 + 0.08 * CGFloat(layer))
                        p.move(to: CGPoint(x: 0, y: size.height))
                        var x: CGFloat = 0
                        while x <= size.width {
                            p.addLine(to: CGPoint(x: x, y: base + CGFloat(sin(Double(x) / 30 + t * (0.9 + Double(layer) * 0.3)) * 8)))
                            x += 6
                        }
                        p.addLine(to: CGPoint(x: size.width, y: size.height))
                        p.closeSubpath()
                        ctx.fill(p, with: .color(Color.cyan.opacity(0.12 + 0.08 * Double(layer))))
                        ctx.stroke(p, with: .color(c1.opacity(0.5)), lineWidth: 1)
                    }
                    for i in 0..<26 {
                        let x = CGFloat((i * 97) % 300)
                        let y = size.height - CGFloat((t * 12 + Double(i * 23)).truncatingRemainder(dividingBy: 300))
                        ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2.5, height: 2.5)), with: .color(Color.cyan.opacity(0.7)))
                    }
                }
                Cover(song: song, size: 170, radius: 18, glow: .cyan)
                    .offset(y: -28 + CGFloat(sin(t * 0.8)) * 5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }
}

// MARK: Orbit Rings (cometOrbit)

/// Three tilted orbits with their own moons circle the cover at different speeds.
struct CometOrbitArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    var body: some View {
        StyleStage(song: song, isPlaying: isPlaying) { t, c1, c2 in
            ZStack {
                Cover(song: song, size: 150, radius: 75, glow: c1)
                ForEach(0..<3, id: \.self) { i in
                    let tilt = Double(i) * 55 - 20
                    let a = t * (0.6 + Double(i) * 0.35) + Double(i)
                    ZStack {
                        Ellipse().stroke(c2.opacity(0.35), lineWidth: 1).frame(width: 270 - CGFloat(i) * 30, height: 90 - CGFloat(i) * 10)
                        Circle()
                            .fill(i == 0 ? c1 : (i == 1 ? c2 : .white))
                            .frame(width: 10, height: 10)
                            .shadow(color: .white, radius: 4)
                            .offset(x: cos(a) * (135 - CGFloat(i) * 15), y: sin(a) * (45 - CGFloat(i) * 5))
                            .zIndex(sin(a) > 0 ? 1 : -1)
                    }
                    .rotationEffect(.degrees(tilt))
                }
            }
        }
    }
}

// MARK: Cut Paper (paperLayersParallax)

/// The palette cut into stacked paper layers behind the cover, shifting at
/// different depths.
struct PaperLayersParallaxArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    var body: some View {
        StyleStage(song: song, isPlaying: isPlaying) { t, c1, c2 in
            ZStack {
                ForEach((0..<5).reversed(), id: \.self) { i in
                    let depth = CGFloat(i + 1)
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(i % 2 == 0 ? c1.opacity(0.35 + 0.1 * Double(i)) : c2.opacity(0.3 + 0.1 * Double(i)))
                        .frame(width: 210 + depth * 12, height: 210 + depth * 12)
                        .rotationEffect(.degrees(Double(i) * 4 - 8 + sin(t * 0.4 + Double(i)) * 2))
                        .offset(x: CGFloat(sin(t * 0.5)) * depth * 3, y: CGFloat(cos(t * 0.4)) * depth * 3)
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 3)
                }
                Cover(song: song, size: 200, radius: 18)
            }
        }
    }
}

// MARK: Sketchbook (chalkboardSketch)

/// A hand-drawn double outline wobbles around the cover like a pencil sketch,
/// with doodled stars.
struct ChalkboardSketchArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    var body: some View {
        StyleStage(song: song, isPlaying: isPlaying) { t, c1, _ in
            let jitterSeed = floor(t * 6)
            ZStack {
                Cover(song: song, size: 200, radius: 6)
                ForEach(0..<2, id: \.self) { k in
                    SketchRect(seed: jitterSeed + Double(k) * 17, wobble: 3.5)
                        .stroke(.white.opacity(0.85 - Double(k) * 0.3), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                        .frame(width: 218 + CGFloat(k) * 8, height: 218 + CGFloat(k) * 8)
                }
                ForEach(0..<5, id: \.self) { i in
                    Image(systemName: "star")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(c1)
                        .rotationEffect(.degrees(jitterSeed * 7 + Double(i) * 40))
                        .offset(x: [-128, 120, -110, 126, 0][i], y: [-118, -100, 120, 112, -138][i])
                }
            }
        }
    }
}

private struct SketchRect: Shape {
    let seed: Double
    let wobble: CGFloat
    func path(in r: CGRect) -> Path {
        func j(_ k: Double) -> CGFloat { CGFloat(sin(seed * 12.9898 + k * 78.233) * 43758.5453).truncatingRemainder(dividingBy: 1) * wobble }
        let pts = [CGPoint(x: r.minX + j(1), y: r.minY + j(2)), CGPoint(x: r.maxX + j(3), y: r.minY + j(4)),
                   CGPoint(x: r.maxX + j(5), y: r.maxY + j(6)), CGPoint(x: r.minX + j(7), y: r.maxY + j(8))]
        var p = Path()
        p.move(to: pts[0])
        for i in 1...4 {
            let a = pts[i - 1], b = pts[i % 4]
            p.addQuadCurve(to: b, control: CGPoint(x: (a.x + b.x) / 2 + j(Double(i) + 9), y: (a.y + b.y) / 2 + j(Double(i) + 13)))
        }
        return p
    }
}

// MARK: Record Shelf (vinylCrateStack)

/// The cover leans in front of a fan of record sleeves that sway as if flipped through.
struct VinylCrateStackArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    var body: some View {
        StyleStage(song: song, isPlaying: isPlaying) { t, c1, c2 in
            ZStack {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: [i % 2 == 0 ? c1 : c2, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 180, height: 180)
                        .overlay(Circle().stroke(.black.opacity(0.3), lineWidth: 18).frame(width: 120))
                        .rotationEffect(.degrees(Double(i - 2) * 7 + sin(t * 0.7 + Double(i)) * 2), anchor: .bottom)
                        .offset(x: CGFloat(i - 2) * 22, y: -14)
                        .opacity(0.8)
                }
                Cover(song: song, size: 190, radius: 6).offset(y: 18).rotationEffect(.degrees(-2))
            }
        }
    }
}

// MARK: Honey Drip (moltenGlassDrip)

/// Glossy drops gather on the cover's bottom edge, stretch and fall.
struct MoltenGlassDripArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    var body: some View {
        StyleStage(song: song, isPlaying: isPlaying) { t, c1, _ in
            ZStack {
                Cover(song: song, size: 210, radius: 22, glow: c1).offset(y: -25)
                Canvas { ctx, size in
                    let edge = size.height / 2 - 25 + 105
                    for i in 0..<6 {
                        let x = size.width / 2 - 85 + CGFloat(i) * 34
                        let cycle = (t / (2.6 + Double(i) * 0.31) + Double(i) * 0.17).truncatingRemainder(dividingBy: 1)
                        let stretch = CGFloat(min(cycle / 0.7, 1)) * 26
                        var neck = Path()
                        neck.addRoundedRect(in: CGRect(x: x - 4, y: edge - 2, width: 8, height: 4 + stretch), cornerSize: CGSize(width: 4, height: 4))
                        ctx.fill(neck, with: .color(c1.opacity(0.85)))
                        if cycle > 0.7 {
                            let fall = CGFloat((cycle - 0.7) / 0.3)
                            let y = edge + stretch + fall * 60
                            ctx.fill(Path(ellipseIn: CGRect(x: x - 5, y: y, width: 10, height: 12)), with: .color(c1.opacity(Double(1 - fall))))
                        }
                    }
                }
            }
        }
    }
}

// MARK: Streamers (confettiBurstLoop)

/// Curling ribbon streamers drift down past the cover.
struct ConfettiBurstLoopArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    var body: some View {
        StyleStage(song: song, isPlaying: isPlaying) { t, c1, c2 in
            ZStack {
                Canvas { ctx, size in
                    let colours = [c1, c2, .yellow, .pink, .cyan]
                    for i in 0..<12 {
                        let x0 = CGFloat((i * 53) % 300)
                        let fall = CGFloat((t * (22 + Double(i % 4) * 6) + Double(i * 41)).truncatingRemainder(dividingBy: 360)) - 40
                        var p = Path()
                        for s in 0..<14 {
                            let y = fall - CGFloat(s) * 4
                            let x = x0 + CGFloat(sin(Double(y) / 14 + Double(i))) * 9
                            if s == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                        }
                        ctx.stroke(p, with: .color(colours[i % colours.count].opacity(0.85)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    }
                }
                Cover(song: song, size: 190, radius: 22, glow: c2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        }
    }
}

// MARK: Lantern (shadowPuppetSilhouette)

/// A lantern swings above the cover; its light and the cover's long shadow
/// sway together.
struct ShadowPuppetSilhouetteArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    var body: some View {
        StyleStage(song: song, isPlaying: isPlaying) { t, c1, _ in
            let swing = sin(t * 1.1) * 0.5
            ZStack {
                Color(red: 0.06, green: 0.04, blue: 0.03)
                RadialGradient(colors: [Color.orange.opacity(0.55), .clear], center: UnitPoint(x: 0.5 + swing * 0.3, y: 0.05), startRadius: 10, endRadius: 260)
                RoundedRectangle(cornerRadius: 18).fill(.black.opacity(0.55))
                    .frame(width: 170, height: 170)
                    .blur(radius: 10)
                    .offset(x: CGFloat(-swing * 60), y: 46)
                    .scaleEffect(x: 1, y: 0.5, anchor: .bottom)
                Cover(song: song, size: 170, radius: 18, glow: c1).offset(y: 10)
                    .brightness(-0.08 + 0.08 * (1 - abs(swing)))
                Image(systemName: "lamp.ceiling.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.orange)
                    .shadow(color: .orange, radius: 10)
                    .offset(y: -128)
                    .rotationEffect(.degrees(swing * 24), anchor: UnitPoint(x: 0.5, y: 0.0))
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }
}

// MARK: Halo Spectrum (liveSpectrum)

/// The real-time spectrum as a halo of bars around a round cover.
struct LiveSpectrumArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    @ObservedObject private var visualizer = AudioVisualizerService.shared
    @ObservedObject private var luaVisualizer = LuaVisualizerStore.shared

    private var colors: [Color] {
        guard let hex = luaVisualizer.activeConfig?.colors, !hex.isEmpty else { return [AppTheme.dynamicAccent, .cyan] }
        return hex.map { Color(hex: $0) }
    }

    var body: some View {
        let sensitivity = Float(luaVisualizer.activeConfig?.sensitivity ?? 1.0)
        let mags = visualizer.magnitudes.map { min(1, max(0, $0 * sensitivity)) }
        ZStack {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let n = max(mags.count, 1)
                // Mirror the bands left/right so the halo is symmetric.
                let bars = n * 2
                for i in 0..<bars {
                    let m = CGFloat(mags[i < n ? i : bars - 1 - i])
                    let a = Double(i) / Double(bars) * 2 * .pi - .pi / 2
                    let inner: CGFloat = 104
                    let outer = inner + 6 + m * 42
                    var p = Path()
                    p.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
                    p.addLine(to: CGPoint(x: c.x + cos(a) * outer, y: c.y + sin(a) * outer))
                    ctx.stroke(p, with: .linearGradient(Gradient(colors: colors), startPoint: c, endPoint: CGPoint(x: c.x + cos(a) * outer, y: c.y + sin(a) * outer)),
                               style: StrokeStyle(lineWidth: 4, lineCap: .round))
                }
            }
            Cover(song: song, size: 196, radius: 98)
        }
        .frame(width: 300, height: 300)
        .drawingGroup()
        .onAppear { if isPlaying { visualizer.start() } }
        .onDisappear { visualizer.stop() }
        .onChange(of: isPlaying) { playing in
            if playing { visualizer.start() } else { visualizer.stop() }
        }
    }
}

// MARK: Turntable (vinylGrooveSpiral)

/// The cover as the label of a spinning record, with a tonearm resting in
/// the groove and a light sheen across the vinyl.
struct VinylGrooveSpiralArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    var body: some View {
        StyleStage(song: song, isPlaying: isPlaying) { t, c1, _ in
            ZStack {
                ZStack {
                    Circle().fill(Color(white: 0.06))
                    ForEach(0..<14, id: \.self) { i in
                        Circle().stroke(Color.white.opacity(0.05), lineWidth: 1).frame(width: 270 - CGFloat(i) * 9)
                    }
                    StyleCover(song: song, size: 120).clipShape(Circle())
                    Circle().fill(Color.black).frame(width: 8)
                }
                .frame(width: 270, height: 270)
                .rotationEffect(.degrees(t * 200))
                AngularGradient(colors: [.clear, .white.opacity(0.12), .clear, .clear, .white.opacity(0.08), .clear], center: .center)
                    .clipShape(Circle()).frame(width: 270, height: 270)
                Capsule().fill(LinearGradient(colors: [.gray, .white], startPoint: .top, endPoint: .bottom))
                    .frame(width: 6, height: 130)
                    .rotationEffect(.degrees(isPlaying ? 28 : 12), anchor: .top)
                    .offset(x: 110, y: -80)
                    .shadow(color: c1.opacity(0.4), radius: 6)
            }
            .animation(LumiMotion.settle, value: isPlaying)
        }
    }
}

// MARK: Mixtape (cassetteReelSpin)

/// A cassette with the cover as its label sticker; the reels spin and the tape
/// visibly moves from one spool to the other over the song.
struct CassetteReelSpinArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    var body: some View {
        StyleStage(song: song, isPlaying: isPlaying) { t, c1, c2 in
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 280, height: 180)
                StyleCover(song: song, size: 250)
                    .frame(width: 250, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .offset(y: -42)
                RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.6)).frame(width: 170, height: 52).offset(y: 22)
                ForEach([-1.0, 1.0], id: \.self) { side in
                    ZStack {
                        Circle().fill(Color(white: 0.22)).frame(width: 36 + (side < 0 ? 10 : 4) * 1)
                        ForEach(0..<6, id: \.self) { k in
                            Capsule().fill(.white.opacity(0.7)).frame(width: 3, height: 10).offset(y: -8).rotationEffect(.degrees(Double(k) * 60))
                        }
                        .rotationEffect(.degrees(t * 160 * side))
                    }
                    .offset(x: side * 50, y: 22)
                }
                Text("SIDE A").font(.system(size: 9, weight: .black)).foregroundStyle(c2).offset(x: -110, y: 70)
                Capsule().fill(c1).frame(width: 40, height: 4).offset(x: 110, y: 70)
            }
        }
    }
}

// MARK: Northern Lights (auroraVeil)

/// Aurora curtains in the artwork's colours ripple over a starfield behind the cover.
struct AuroraVeilArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    var body: some View {
        StyleStage(song: song, isPlaying: isPlaying) { t, c1, c2 in
            ZStack {
                Color(red: 0.01, green: 0.02, blue: 0.06)
                Canvas { ctx, size in
                    for i in 0..<40 {
                        let x = CGFloat((i * 71) % 300), y = CGFloat((i * 43) % 300)
                        ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(.white.opacity(0.3 + 0.5 * osc(t, 3, Double(i)))))
                    }
                    for k in 0..<3 {
                        var x: CGFloat = 0
                        while x < size.width {
                            let top = CGFloat(40 + 30 * sin(Double(x) / 40 + t * 0.7 + Double(k)))
                            let h = CGFloat(90 + 40 * sin(Double(x) / 23 - t * 1.1 + Double(k) * 2))
                            ctx.fill(Path(CGRect(x: x, y: top, width: 5, height: h)),
                                     with: .linearGradient(Gradient(colors: [(k == 1 ? c2 : c1).opacity(0.0), (k == 1 ? c2 : c1).opacity(0.45), .clear]),
                                                           startPoint: CGPoint(x: x, y: top), endPoint: CGPoint(x: x, y: top + h)))
                            x += 5
                        }
                    }
                }
                .blur(radius: 6)
                Cover(song: song, size: 170, radius: 22, glow: c1).offset(y: 30)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }
}

// MARK: Still Water (rippleReflection)

/// The cover above its reflection in water that ripples in slices.
struct RippleReflectionArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    var body: some View {
        StyleStage(song: song, isPlaying: isPlaying) { t, c1, _ in
            VStack(spacing: 4) {
                Cover(song: song, size: 160, radius: 16, glow: c1)
                ZStack {
                    ForEach(0..<10, id: \.self) { i in
                        StyleCover(song: song, size: 160)
                            .scaleEffect(y: -1)
                            .frame(width: 160, height: 120, alignment: .top)
                            .mask(Rectangle().frame(width: 160, height: 12).offset(y: CGFloat(i) * 12 - 54))
                            .offset(x: CGFloat(sin(t * 2.2 + Double(i) * 0.6)) * CGFloat(1 + i))
                    }
                }
                .frame(width: 180, height: 120)
                .clipped()
                .opacity(0.4)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
            }
        }
    }
}

// MARK: Neon Frame (neonSignFlicker)

/// A neon tube frames the cover and hums; now and then a section flickers.
struct NeonSignFlickerArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    var body: some View {
        StyleStage(song: song, isPlaying: isPlaying) { t, c1, c2 in
            // A short flicker roughly every 4 s.
            let cycle = t.truncatingRemainder(dividingBy: 4.1)
            let flick = cycle < 0.25 ? (sin(cycle * 90) > 0 ? 0.25 : 1.0) : 1.0
            ZStack {
                Color(red: 0.04, green: 0.02, blue: 0.06)
                Cover(song: song, size: 190, radius: 10)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(c2, lineWidth: 4)
                    .frame(width: 220, height: 220)
                    .shadow(color: c2.opacity(flick), radius: 6)
                    .shadow(color: c2.opacity(0.7 * flick), radius: 18)
                    .opacity(0.4 + 0.6 * flick)
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(c1, lineWidth: 3)
                    .frame(width: 244, height: 244)
                    .shadow(color: c1, radius: 8 + 4 * osc(t, 1.7))
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }
}

// MARK: Tape Glitch (vhsScanGlitch)

/// Scanlines and a rolling tracking band; every few seconds the picture tears
/// with an RGB split.
struct VHSScanGlitchArtworkView: View {
    let song: Song?
    let isPlaying: Bool

    var body: some View {
        StyleStage(song: song, isPlaying: isPlaying) { t, _, _ in
            let tear = t.truncatingRemainder(dividingBy: 3.7) < 0.18
            let split: CGFloat = tear ? 6 : 1.2
            ZStack {
                StyleCover(song: song, size: 230).colorMultiply(.red).offset(x: -split).blendMode(.screen)
                StyleCover(song: song, size: 230).colorMultiply(.green).blendMode(.screen)
                StyleCover(song: song, size: 230).colorMultiply(.blue).offset(x: split).blendMode(.screen)
                Canvas { ctx, size in
                    var y: CGFloat = 0
                    while y < size.height {
                        ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.25)))
                        y += 3
                    }
                    let band = CGFloat((t * 40).truncatingRemainder(dividingBy: Double(size.height + 40))) - 20
                    ctx.fill(Path(CGRect(x: 0, y: band, width: size.width, height: 16)), with: .color(.white.opacity(0.08)))
                }
                if tear {
                    StyleCover(song: song, size: 230)
                        .mask(Rectangle().frame(height: 26).offset(y: CGFloat(sin(t * 50)) * 60))
                        .offset(x: 14)
                }
            }
            .frame(width: 230, height: 230)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .compositingGroup()
        }
    }
}
