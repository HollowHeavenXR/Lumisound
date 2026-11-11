import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Timeline

struct LumisoundEntry: TimelineEntry {
    let date: Date
    let now: NowPlayingSnapshot
    let artwork: UIImage?
}

/// Reads the app's `NowPlayingSnapshot` (one atomic record, see
/// WidgetDataService). The app reloads timelines on every change; between
/// reloads the system animates progress from the snapshot's timeline.
struct LumisoundWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> LumisoundEntry {
        var s = NowPlayingSnapshot.empty
        s.trackID = "placeholder"
        s.title = "Track Title"
        s.artist = "Artist"
        s.duration = 210
        s.position = 64
        s.anchor = Date()
        return LumisoundEntry(date: Date(), now: s, artwork: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (LumisoundEntry) -> Void) {
        completion(context.isPreview && NowPlayingSnapshot.load() == nil ? placeholder(in: context) : entry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LumisoundEntry>) -> Void) {
        let first = entry(at: Date())
        var entries = [first]
        // If the app says nothing more (killed, or a skipped reload), stop the
        // bar at the end of the track instead of showing "playing" forever.
        if let end = first.now.endDate, end > first.date {
            entries.append(LumisoundEntry(date: end, now: first.now.finished, artwork: first.artwork))
        }
        completion(Timeline(entries: entries, policy: .never))
    }

    private func entry(at date: Date) -> LumisoundEntry {
        let s = NowPlayingSnapshot.load() ?? .empty
        let art = s.hasTrack ? NowPlayingSnapshot.loadImage(s.artworkFile, maxPixel: 640) : nil
        return LumisoundEntry(date: date, now: s, artwork: art)
    }
}

// MARK: - Small

struct WidgetSmallView: View {
    let entry: LumisoundEntry
    private var s: NowPlayingSnapshot { entry.now }

    var body: some View {
        if s.isWide {
            // 16:9 video frame: shown whole, not cropped to the square.
            VStack(alignment: .leading, spacing: 6) {
                NowPlayingArtwork(image: entry.artwork, snapshot: s, height: 70, cornerRadius: 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                NowPlayingLabels(snapshot: s, titleSize: 13, showsDetail: false)
                Spacer(minLength: 0)
                footer
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    NowPlayingArtwork(image: entry.artwork, snapshot: s, height: 64, cornerRadius: 12)
                    Spacer(minLength: 0)
                    playButton
                }
                Spacer(minLength: 6)
                NowPlayingLabels(snapshot: s, titleSize: 13, showsDetail: false)
                Spacer(minLength: 6)
                NowPlayingProgressBar(snapshot: s, height: 4)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            NowPlayingProgressBar(snapshot: s, height: 4)
            playButton
        }
    }

    private var playButton: some View {
        Button(intent: TogglePlaybackIntent()) {
            Image(systemName: s.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 30, height: 30)
                .background(Circle().fill(s.tintColor))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Medium

struct WidgetMediumView: View {
    let entry: LumisoundEntry
    private var s: NowPlayingSnapshot { entry.now }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            NowPlayingArtwork(image: entry.artwork, snapshot: s, height: s.isWide ? 82 : 118, cornerRadius: 14)
            VStack(alignment: .leading, spacing: 0) {
                NowPlayingLabels(snapshot: s, titleSize: 15, titleLines: s.isWide ? 1 : 2)
                Spacer(minLength: 6)
                NowPlayingProgressBar(snapshot: s)
                NowPlayingTimeRow(snapshot: s, font: .system(size: 10, weight: .medium))
                    .padding(.top, 3)
                Spacer(minLength: 4)
                NowPlayingControls(snapshot: s, size: 16, spacing: 18, showsFavorite: true)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Large

struct WidgetLargeView: View {
    let entry: LumisoundEntry
    private var s: NowPlayingSnapshot { entry.now }

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geo in
                // Wide art spans the widget at 16:9; square art is a centred square.
                let h = s.isWide ? min(geo.size.height, (geo.size.width * 9 / 16).rounded()) : geo.size.height
                NowPlayingArtwork(image: entry.artwork, snapshot: s, height: h, cornerRadius: 18)
                    .shadow(color: s.tintColor.opacity(0.35), radius: 18, y: 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            NowPlayingLabels(snapshot: s, titleSize: 17, alignment: .center)
                .frame(maxWidth: .infinity)
            VStack(spacing: 4) {
                NowPlayingProgressBar(snapshot: s, height: 5)
                NowPlayingTimeRow(snapshot: s)
            }
            NowPlayingControls(snapshot: s, size: 22, spacing: 30, showsFavorite: true)
        }
    }
}

// MARK: - Lock Screen

struct WidgetCircularView: View {
    let entry: LumisoundEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            NowPlayingRing(snapshot: entry.now)
                .padding(3)
            Image(systemName: !entry.now.hasTrack ? "music.note" : entry.now.isPlaying ? "waveform" : "pause.fill")
                .font(.system(size: 17, weight: .semibold))
                .widgetAccentable()
        }
        .widgetLabel {
            Text(entry.now.hasTrack ? entry.now.title : "Lumisound")
        }
    }
}

struct WidgetRectangularView: View {
    let entry: LumisoundEntry
    private var s: NowPlayingSnapshot { entry.now }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: s.isPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: 10, weight: .bold))
                    .widgetAccentable()
                Text(s.hasTrack ? s.title : "Nothing Playing")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            if !s.artist.isEmpty {
                Text(s.artist)
                    .font(.system(size: 12))
                    .opacity(0.75)
                    .lineLimit(1)
            }
            if s.hasTrack {
                NowPlayingProgressBar(snapshot: s, tint: .primary, height: 3)
                    .widgetAccentable()
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WidgetInlineView: View {
    let entry: LumisoundEntry

    var body: some View {
        if entry.now.hasTrack {
            Text("\(Image(systemName: entry.now.isPlaying ? "waveform" : "pause.fill")) \(entry.now.title)\(entry.now.artist.isEmpty ? "" : " — \(entry.now.artist)")")
        } else {
            Text("Lumisound: Nothing Playing")
        }
    }
}

// MARK: - Entry view

struct LumisoundWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LumisoundEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            WidgetCircularView(entry: entry)
                .containerBackground(.clear, for: .widget)
        case .accessoryRectangular:
            WidgetRectangularView(entry: entry)
                .containerBackground(.clear, for: .widget)
        case .accessoryInline:
            WidgetInlineView(entry: entry)
                .containerBackground(.clear, for: .widget)
        case .systemMedium:
            WidgetMediumView(entry: entry)
                .containerBackground(for: .widget) { NowPlayingBackdrop(snapshot: entry.now) }
        case .systemLarge:
            WidgetLargeView(entry: entry)
                .containerBackground(for: .widget) { NowPlayingBackdrop(snapshot: entry.now) }
        default:
            WidgetSmallView(entry: entry)
                .containerBackground(for: .widget) { NowPlayingBackdrop(snapshot: entry.now) }
        }
    }
}

// MARK: - Configuration

struct LumisoundWidget: Widget {
    let kind = "LumisoundWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LumisoundWidgetProvider()) { entry in
            LumisoundWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("The track playing in Lumisound, in sync with the app.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

@main
struct LumisoundWidgetBundle: WidgetBundle {
    var body: some Widget {
        LumisoundWidget()
        LumisoundLiveActivity()
    }
}
