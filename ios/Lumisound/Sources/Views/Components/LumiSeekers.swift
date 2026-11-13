import SwiftUI

// MARK: - Lumisound seekers
//
// Every Now Playing seeker, redrawn (2026-11). Each style has its own idea;
// they share `SeekerModel` (drag → fraction → seek) and `SeekerTimes` so
// seeking behaves identically everywhere. Ambient motion is wall-clock
// driven (TimelineView at LumiMotion.frame, paused when not playing) so the
// frequent position ticks never freeze it.

/// Shared drag state for a horizontal seeker.
private struct SeekerModel {
    let position: TimeInterval
    let duration: TimeInterval
    var dragFraction: Double?

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, dragFraction ?? (position / duration)))
    }

    var shown: TimeInterval { dragFraction.map { $0 * duration } ?? position }
}

private func seekGesture(width: CGFloat, drag: Binding<Double?>, duration: TimeInterval, onSeek: @escaping (TimeInterval) -> Void) -> some Gesture {
    DragGesture(minimumDistance: 0)
        .onChanged { v in drag.wrappedValue = min(max(v.location.x / max(width, 1), 0), 1) }
        .onEnded { v in
            let f = min(max(v.location.x / max(width, 1), 0), 1)
            onSeek(f * duration)
            drag.wrappedValue = nil
        }
}

/// Elapsed / remaining under a seeker.
private struct SeekerTimes: View {
    let shown: TimeInterval
    let duration: TimeInterval
    var emphasise = false

    var body: some View {
        HStack {
            Text(shown.formattedAsMinutesSeconds).monospacedDigit()
            Spacer()
            Text("-" + max(0, duration - shown).formattedAsMinutesSeconds).monospacedDigit()
        }
        .font(emphasise ? .caption.weight(.semibold) : .caption)
        .foregroundStyle(emphasise ? AppTheme.textPrimary : AppTheme.textSecondary)
    }
}

// MARK: Glide (classic)

/// A thin track that thickens under your finger; the thumb turns into a
/// time bubble while dragging.
struct ClassicScrubberView: View {
    let position: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let onSeek: (TimeInterval) -> Void
    @State private var drag: Double?

    var body: some View {
        let m = SeekerModel(position: position, duration: duration, dragFraction: drag)
        VStack(spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                let x = w * m.progress
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.textSecondary.opacity(0.18)).frame(height: drag == nil ? 4 : 8)
                    Capsule()
                        .fill(LinearGradient(colors: [AppTheme.accentSoft, AppTheme.dynamicAccent], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, x), height: drag == nil ? 4 : 8)
                    Group {
                        if drag != nil {
                            Text(m.shown.formattedAsMinutesSeconds)
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .foregroundStyle(.white)
                                .background(AppTheme.dynamicAccent, in: Capsule())
                                .offset(y: -22)
                        } else {
                            Circle().fill(.white).frame(width: 12, height: 12)
                                .shadow(color: AppTheme.dynamicAccent.opacity(0.6), radius: 6)
                        }
                    }
                    .position(x: min(max(x, 6), w - 6), y: 10)
                }
                .frame(height: 20)
                .contentShape(Rectangle().inset(by: -14))
                .gesture(seekGesture(width: w, drag: $drag, duration: duration, onSeek: onSeek))
                .animation(LumiMotion.snap, value: drag == nil)
            }
            .frame(height: 20)
            SeekerTimes(shown: m.shown, duration: duration)
        }
    }
}

// MARK: Orbit (ring)

/// A dial: drag around the ring. A comet rides the progress arc, its tail
/// fading behind it; the centre shows the time.
struct RingScrubberView: View {
    let position: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let onSeek: (TimeInterval) -> Void
    @State private var dragAngle: Double?

    private var progress: Double {
        guard duration > 0 else { return 0 }
        if let a = dragAngle { return min(max(a / (2 * .pi), 0), 1) }
        return min(1, position / duration)
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let r = side / 2 - 8
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                Circle().stroke(AppTheme.textSecondary.opacity(0.15), lineWidth: 6).frame(width: r * 2, height: r * 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(AngularGradient(colors: [AppTheme.dynamicAccent.opacity(0.05), AppTheme.dynamicAccent], center: .center,
                                            startAngle: .degrees(0), endAngle: .degrees(360 * max(progress, 0.01))),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: r * 2, height: r * 2)
                TimelineView(.animation(minimumInterval: LumiMotion.frame, paused: !isPlaying)) { ctx in
                    let glow = isPlaying ? ArtworkClock.pingPong(ctx.date, legDuration: 0.9) : 0
                    let a = progress * 2 * .pi - .pi / 2
                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: AppTheme.dynamicAccent, radius: 6 + 6 * glow)
                        .position(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                }
                VStack(spacing: 2) {
                    Text((dragAngle.map { $0 / (2 * .pi) * duration } ?? position).formattedAsMinutesSeconds)
                        .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(AppTheme.textPrimary)
                    Text("of " + duration.formattedAsMinutesSeconds).font(.caption2).foregroundStyle(AppTheme.textSecondary)
                }
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        var a = atan2(v.location.y - c.y, v.location.x - c.x) + .pi / 2
                        if a < 0 { a += 2 * .pi }
                        dragAngle = a
                    }
                    .onEnded { _ in
                        if let a = dragAngle { onSeek(min(max(a / (2 * .pi), 0), 1) * duration) }
                        dragAngle = nil
                    }
            )
        }
        .frame(height: 170)
    }
}

// MARK: Skyline (bars)

/// A city skyline of 40 buildings; the played part lights up window by
/// window and the roofline breathes with the music.
struct BarsScrubberView: View {
    let position: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let onSeek: (TimeInterval) -> Void
    @State private var drag: Double?
    private let count = 40

    private func height(_ i: Int) -> CGFloat {
        // Stable per-index skyline: a hash, not random per render.
        var h = UInt32(truncatingIfNeeded: i &* 2654435761)
        h ^= h >> 13
        return 0.35 + CGFloat(h % 1000) / 1000 * 0.65
    }

    var body: some View {
        let m = SeekerModel(position: position, duration: duration, dragFraction: drag)
        VStack(spacing: 8) {
            GeometryReader { geo in
                TimelineView(.animation(minimumInterval: LumiMotion.frame, paused: !isPlaying)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(0..<count, id: \.self) { i in
                            let lit = Double(i) / Double(count) < m.progress
                            let sway = isPlaying && lit ? 0.08 * sin(t * 4 + Double(i) * 0.7) : 0
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .fill(lit ? AnyShapeStyle(LinearGradient(colors: [AppTheme.dynamicAccent, AppTheme.accentSoft], startPoint: .top, endPoint: .bottom))
                                          : AnyShapeStyle(AppTheme.textSecondary.opacity(0.18)))
                                .frame(height: geo.size.height * min(1, height(i) + sway))
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(seekGesture(width: geo.size.width, drag: $drag, duration: duration, onSeek: onSeek))
            }
            .frame(height: 38)
            SeekerTimes(shown: m.shown, duration: duration)
        }
    }
}

// MARK: Flip clock (digital)

/// Big LED digits for elapsed and remaining with a dotted LED bar between.
struct DigitalScrubberView: View {
    let position: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let onSeek: (TimeInterval) -> Void
    @State private var drag: Double?

    var body: some View {
        let m = SeekerModel(position: position, duration: duration, dragFraction: drag)
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(m.shown.formattedAsMinutesSeconds)
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.dynamicAccent)
                    .shadow(color: AppTheme.dynamicAccent.opacity(0.6), radius: 6)
                    .contentTransition(.numericText())
                Spacer()
                Text("-" + max(0, duration - m.shown).formattedAsMinutesSeconds)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            GeometryReader { geo in
                let cells = 32
                HStack(spacing: 3) {
                    ForEach(0..<cells, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Double(i) / Double(cells) < m.progress ? AppTheme.dynamicAccent : AppTheme.textSecondary.opacity(0.15))
                    }
                }
                .contentShape(Rectangle())
                .gesture(seekGesture(width: geo.size.width, drag: $drag, duration: duration, onSeek: onSeek))
            }
            .frame(height: 8)
        }
    }
}

// MARK: Capsule meter (pill)

/// A thick capsule that fills like a meter, with the elapsed time riding
/// inside the fill.
struct PillScrubberView: View {
    let position: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let onSeek: (TimeInterval) -> Void
    @State private var drag: Double?

    var body: some View {
        let m = SeekerModel(position: position, duration: duration, dragFraction: drag)
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(AppTheme.textSecondary.opacity(0.16))
                Capsule()
                    .fill(LinearGradient(colors: [AppTheme.dynamicAccent, AppTheme.dynamicAccentSecondary], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(40, w * m.progress))
                HStack {
                    Text(m.shown.formattedAsMinutesSeconds).foregroundStyle(.white)
                    Spacer()
                    Text("-" + max(0, duration - m.shown).formattedAsMinutesSeconds).foregroundStyle(AppTheme.textSecondary)
                }
                .font(.caption.weight(.bold).monospacedDigit())
                .padding(.horizontal, 12)
            }
            .contentShape(Rectangle())
            .gesture(seekGesture(width: w, drag: $drag, duration: duration, onSeek: onSeek))
            .scaleEffect(y: drag == nil ? 1 : 1.12)
            .animation(LumiMotion.snap, value: drag == nil)
        }
        .frame(height: 30)
    }
}

// MARK: Neon tube (neonLine)

/// A glowing neon tube; the lit part hums faintly and the head sparks.
struct NeonLineScrubberView: View {
    let position: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let onSeek: (TimeInterval) -> Void
    @State private var drag: Double?

    var body: some View {
        let m = SeekerModel(position: position, duration: duration, dragFraction: drag)
        VStack(spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                TimelineView(.animation(minimumInterval: LumiMotion.frame, paused: !isPlaying)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    let hum = isPlaying ? 0.85 + 0.15 * sin(t * 37) * sin(t * 3.1) : 1
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppTheme.textSecondary.opacity(0.12)).frame(height: 3)
                        Capsule().fill(AppTheme.dynamicAccent).frame(width: w * m.progress, height: 3)
                            .shadow(color: AppTheme.dynamicAccent.opacity(hum), radius: 4)
                            .shadow(color: AppTheme.dynamicAccent.opacity(0.6 * hum), radius: 10)
                        Circle().fill(.white).frame(width: 7, height: 7)
                            .shadow(color: .white, radius: 4 + 3 * (isPlaying ? abs(sin(t * 9)) : 0))
                            .position(x: w * m.progress, y: 6)
                    }
                    .frame(height: 12)
                }
                .contentShape(Rectangle().inset(by: -14))
                .gesture(seekGesture(width: w, drag: $drag, duration: duration, onSeek: onSeek))
            }
            .frame(height: 12)
            SeekerTimes(shown: m.shown, duration: duration)
        }
    }
}

// MARK: Beads (dotTrack)

/// A string of 28 beads; played beads glow, the current one pulses on the beat.
struct DotTrackScrubberView: View {
    let position: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let onSeek: (TimeInterval) -> Void
    @State private var drag: Double?
    private let count = 28

    var body: some View {
        let m = SeekerModel(position: position, duration: duration, dragFraction: drag)
        VStack(spacing: 8) {
            GeometryReader { geo in
                TimelineView(.animation(minimumInterval: LumiMotion.frame, paused: !isPlaying)) { ctx in
                    let pulse = isPlaying ? ArtworkClock.pingPong(ctx.date, legDuration: 0.6) : 0
                    let current = min(count - 1, Int(m.progress * Double(count)))
                    HStack(spacing: 0) {
                        ForEach(0..<count, id: \.self) { i in
                            Circle()
                                .fill(i < current ? AppTheme.dynamicAccent : (i == current ? Color.white : AppTheme.textSecondary.opacity(0.2)))
                                .frame(width: i == current ? 9 + 3 * pulse : 6, height: i == current ? 9 + 3 * pulse : 6)
                                .shadow(color: i == current ? AppTheme.dynamicAccent : .clear, radius: 5)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .contentShape(Rectangle())
                .gesture(seekGesture(width: geo.size.width, drag: $drag, duration: duration, onSeek: onSeek))
            }
            .frame(height: 16)
            SeekerTimes(shown: m.shown, duration: duration)
        }
    }
}

// MARK: Chapters (segmented)

/// Eight chapters; each fills in turn and the current one shows its own progress.
struct SegmentedScrubberView: View {
    let position: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let onSeek: (TimeInterval) -> Void
    @State private var drag: Double?
    private let parts = 8

    var body: some View {
        let m = SeekerModel(position: position, duration: duration, dragFraction: drag)
        VStack(spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 4) {
                    ForEach(0..<parts, id: \.self) { i in
                        let local = min(1, max(0, m.progress * Double(parts) - Double(i)))
                        GeometryReader { seg in
                            ZStack(alignment: .leading) {
                                Capsule().fill(AppTheme.textSecondary.opacity(0.18))
                                Capsule().fill(AppTheme.dynamicAccent).frame(width: seg.size.width * local)
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(seekGesture(width: geo.size.width, drag: $drag, duration: duration, onSeek: onSeek))
            }
            .frame(height: drag == nil ? 5 : 9)
            .animation(LumiMotion.snap, value: drag == nil)
            HStack {
                Text(m.shown.formattedAsMinutesSeconds).monospacedDigit()
                Spacer()
                Text("Part \(min(parts, Int(m.progress * Double(parts)) + 1)) of \(parts)")
                Spacer()
                Text("-" + max(0, duration - m.shown).formattedAsMinutesSeconds).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(AppTheme.textSecondary)
        }
    }
}

// MARK: Hairline (minimal)

/// One hairline. Times only appear while you touch it.
struct MinimalScrubberView: View {
    let position: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let onSeek: (TimeInterval) -> Void
    @State private var drag: Double?

    var body: some View {
        let m = SeekerModel(position: position, duration: duration, dragFraction: drag)
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(AppTheme.textSecondary.opacity(0.2))
                    Rectangle().fill(AppTheme.textPrimary).frame(width: geo.size.width * m.progress)
                }
                .frame(height: drag == nil ? 1.5 : 5)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(seekGesture(width: geo.size.width, drag: $drag, duration: duration, onSeek: onSeek))
            }
            .frame(height: 22)
            SeekerTimes(shown: m.shown, duration: duration, emphasise: true)
                .opacity(drag == nil ? 0 : 1)
        }
        .animation(LumiMotion.snap, value: drag == nil)
    }
}

// MARK: Tape measure (ruler)

/// A fixed needle; the tape (ticks every 5 s, numbers every 30 s) slides
/// under it. Drag the tape itself to scrub.
struct RulerScrubberView: View {
    let position: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let onSeek: (TimeInterval) -> Void
    @State private var dragStart: TimeInterval?
    @State private var dragTime: TimeInterval?
    private let pxPerSecond: CGFloat = 6

    var body: some View {
        let shown = dragTime ?? position
        VStack(spacing: 6) {
            GeometryReader { geo in
                let mid = geo.size.width / 2
                Canvas { ctx, size in
                    let first = Int(max(0, shown - Double(mid / pxPerSecond)) / 5) * 5
                    let last = min(duration, shown + Double(mid / pxPerSecond))
                    var s = Double(first)
                    while s <= last {
                        let x = mid + CGFloat(s - shown) * pxPerSecond
                        let major = Int(s) % 30 == 0
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: size.height))
                        p.addLine(to: CGPoint(x: x, y: size.height - (major ? 16 : 8)))
                        ctx.stroke(p, with: .color(s <= shown ? AppTheme.dynamicAccent : AppTheme.textSecondary.opacity(0.5)), lineWidth: major ? 1.5 : 1)
                        if major {
                            ctx.draw(Text(TimeInterval(s).formattedAsMinutesSeconds).font(.system(size: 9).monospacedDigit()).foregroundColor(AppTheme.textSecondary),
                                     at: CGPoint(x: x, y: size.height - 24))
                        }
                        s += 5
                    }
                }
                .overlay {
                    Rectangle().fill(AppTheme.dynamicAccent).frame(width: 2).shadow(color: AppTheme.dynamicAccent, radius: 4)
                }
                .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .leading, endPoint: .trailing))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if dragStart == nil { dragStart = position }
                            dragTime = min(max((dragStart ?? position) - Double(v.translation.width / pxPerSecond), 0), duration)
                        }
                        .onEnded { _ in
                            if let t = dragTime { onSeek(t) }
                            dragStart = nil
                            dragTime = nil
                        }
                )
            }
            .frame(height: 40)
            SeekerTimes(shown: shown, duration: duration)
        }
    }
}

// MARK: Mirror wave (waveform)

/// The track's real waveform mirrored above and below a centre line; the
/// played half is lit, and a glowing playhead rides on top.
struct WaveformScrubberView: View {
    let url: URL
    let position: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let onSeek: (TimeInterval) -> Void
    @State private var drag: Double?

    private func wave(_ color: UIColor) -> some View {
        RustWaveformView(url: url, color: Color(color))
    }

    var body: some View {
        let m = SeekerModel(position: position, duration: duration, dragFraction: drag)
        VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    VStack(spacing: 1) {
                        wave(UIColor(AppTheme.textSecondary).withAlphaComponent(0.3))
                        wave(UIColor(AppTheme.textSecondary).withAlphaComponent(0.14)).scaleEffect(y: -1)
                    }
                    VStack(spacing: 1) {
                        wave(UIColor(AppTheme.dynamicAccent))
                        wave(UIColor(AppTheme.dynamicAccent).withAlphaComponent(0.45)).scaleEffect(y: -1)
                    }
                    .mask(alignment: .leading) { Rectangle().frame(width: max(2, w * m.progress)) }
                    TimelineView(.animation(minimumInterval: LumiMotion.frame, paused: !isPlaying)) { ctx in
                        let glow = isPlaying ? ArtworkClock.pingPong(ctx.date, legDuration: 0.8) : 0
                        Capsule().fill(.white).frame(width: 2.5)
                            .shadow(color: AppTheme.dynamicAccent, radius: 3 + 5 * glow)
                    }
                    .offset(x: max(0, w * m.progress - 1))
                }
                .contentShape(Rectangle())
                .gesture(seekGesture(width: w, drag: $drag, duration: duration, onSeek: onSeek))
            }
            .frame(height: 60)
            SeekerTimes(shown: m.shown, duration: duration)
        }
    }
}

// MARK: Waveform (Rust peaks)

/// Peaks per track from the Lumisound core (`waveformPeaks`: 200 values,
/// 0…1), decoded once per file off the main thread and shared by every
/// waveform drawn for it (the mirror seeker draws four).
@MainActor
final class WaveformPeaksCache {
    static let shared = WaveformPeaksCache()
    private var done: [String: [Float]] = [:]
    private var inFlight: [String: Task<[Float], Never>] = [:]

    func peaks(for url: URL) async -> [Float] {
        let key = url.path
        if let p = done[key] { return p }
        if let t = inFlight[key] { return await t.value }
        let t = Task.detached(priority: .utility) { () -> [Float] in
            (waveformPeaks(path: key, cacheDir: CoreAudio.unlockDir) ?? []).map(Float.init)
        }
        inFlight[key] = t
        let p = await t.value
        inFlight[key] = nil
        done[key] = p
        if done.count > 64 { done.removeAll(keepingCapacity: true); done[key] = p }
        return p
    }
}

/// Striped waveform bars (2 pt wide, 1.5 pt apart) from the Rust peaks.
struct RustWaveformView: View {
    let url: URL
    let color: Color
    @State private var peaks: [Float] = []

    var body: some View {
        Canvas { ctx, size in
            guard !peaks.isEmpty else { return }
            let bar: CGFloat = 2, gap: CGFloat = 1.5
            let count = max(1, Int((size.width + gap) / (bar + gap)))
            let loudest = CGFloat(max(peaks.max() ?? 1, 0.05))
            for i in 0..<count {
                // Max over the peaks this bar covers, so short hits aren't lost.
                let a = i * peaks.count / count, b = max(a + 1, (i + 1) * peaks.count / count)
                let v = CGFloat(peaks[a..<min(b, peaks.count)].max() ?? 0) / loudest
                let h = max(1, v * size.height * 0.9)
                let rect = CGRect(x: CGFloat(i) * (bar + gap), y: size.height - h, width: bar, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
            }
        }
        .task(id: url) { peaks = await WaveformPeaksCache.shared.peaks(for: url) }
        .accessibilityHidden(true)
    }
}
