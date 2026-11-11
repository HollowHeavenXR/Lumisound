import Foundation
import ImageIO
import SwiftUI
import UIKit

/// Everything the Home Screen / Lock Screen widgets and the Live Activity show
/// for the current track, as one value.
///
/// Compiled into the app and the widget extension. The app writes it as a
/// single JSON blob in the App Group (`save`), so the widget can never read a
/// new title next to the previous track's artwork or timing, which separate
/// keys allowed. The Live Activity carries the same value as its
/// `ContentState`, so both surfaces are built from identical data.
///
/// Timing: `position` was the playback position at `anchor`, advancing at
/// `rate` × real time while `isPlaying`. Views turn that into wall-clock dates
/// (`wallRange`) so the system can animate the progress bar and time labels
/// on its own between updates, and the app re-anchors whenever the real
/// position drifts from that prediction (see `WidgetDataService.resync`).
struct NowPlayingSnapshot: Codable, Hashable, Sendable {
    var trackID: String
    var title: String
    var artist: String
    /// "Rust engine · LMS OPUS · 48 kHz" — how the track is being played.
    var detail: String?
    var bpm: Double?
    var isPlaying: Bool
    var position: TimeInterval
    var duration: TimeInterval
    /// Playback speed (1 = normal).
    var rate: Double
    var anchor: Date
    var isFavorite: Bool
    /// Artwork file names inside `artworkDirectory`, one per track; nil when
    /// the track has no artwork (never the previous track's file).
    var artworkFile: String?
    /// Smaller copy for the Live Activity, whose renderer refuses large images.
    var thumbFile: String?
    /// Artwork width / height after letterbox trimming. ≥ `wideAspect` means
    /// a video frame, which is shown 16:9 instead of being cropped square.
    var artworkAspect: Double
    /// Average artwork colour (0xRRGGBB), used to tint backgrounds and bars.
    var tint: UInt32?

    static let empty = NowPlayingSnapshot(
        trackID: "", title: "", artist: "", detail: nil, bpm: nil, isPlaying: false,
        position: 0, duration: 0, rate: 1, anchor: .distantPast, isFavorite: false,
        artworkFile: nil, thumbFile: nil, artworkAspect: 1, tint: nil
    )

    static let defaultsKey = "now_playing_snapshot_v2"
    static let artworkDirectory = "NowPlayingArt"
    static let wideAspect = 1.3

    var hasTrack: Bool { !title.isEmpty }
    var isWide: Bool { artworkAspect >= Self.wideAspect }
    private var safeRate: Double { rate.isFinite && rate > 0.05 ? rate : 1 }

    /// Track position at `date`, clamped to the track.
    func elapsed(at date: Date = Date()) -> TimeInterval {
        guard isPlaying else { return clamp(position) }
        return clamp(position + date.timeIntervalSince(anchor) * safeRate)
    }

    private func clamp(_ t: TimeInterval) -> TimeInterval {
        duration > 0 ? min(max(0, t), duration) : max(0, t)
    }

    /// Wall-clock span of the whole track at the current speed: "now" sits at
    /// the current position. Feeds `ProgressView(timerInterval:)` and
    /// `Text(timerInterval:)`.
    var wallRange: ClosedRange<Date> {
        let start = anchor.addingTimeInterval(-position / safeRate)
        let end = start.addingTimeInterval(max(duration, position) / safeRate)
        return start...max(start, end)
    }

    /// When the track will finish if nothing changes; nil while paused.
    var endDate: Date? {
        guard isPlaying, duration > 0 else { return nil }
        return wallRange.upperBound
    }

    /// Whether the system can animate progress on its own right now.
    var isLive: Bool { isPlaying && duration > 0 && (endDate ?? .distantPast) > Date() }

    var fraction: Double { duration > 0 ? min(1, max(0, elapsed() / duration)) : 0 }

    /// Normal speed: the elapsed-time label can tick by itself. At other
    /// speeds a ticking label would count real seconds, not track seconds.
    var isNormalSpeed: Bool { abs(safeRate - 1) < 0.01 }

    /// The same track paused at its end — what a widget shows once the track's
    /// time has run out without the app saying what came next.
    var finished: NowPlayingSnapshot {
        var s = self
        s.isPlaying = false
        s.position = duration
        s.anchor = endDate ?? anchor
        return s
    }

    var tintColor: Color {
        guard let tint else { return Color(red: 0.36, green: 0.85, blue: 0.95) }
        return Color(red: Double((tint >> 16) & 0xFF) / 255, green: Double((tint >> 8) & 0xFF) / 255, blue: Double(tint & 0xFF) / 255)
    }

    /// Dark, saturated version of the tint for backgrounds.
    var backdropColor: Color {
        guard let tint else { return Color(white: 0.08) }
        let r = Double((tint >> 16) & 0xFF) / 255, g = Double((tint >> 8) & 0xFF) / 255, b = Double(tint & 0xFF) / 255
        return Color(red: r * 0.32, green: g * 0.32, blue: b * 0.32)
    }

    // MARK: App Group storage

    static func load(from defaults: UserDefaults? = UserDefaults(suiteName: AppGroup.id)) -> NowPlayingSnapshot? {
        guard let data = defaults?.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
    }

    func save(to defaults: UserDefaults? = UserDefaults(suiteName: AppGroup.id)) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults?.set(data, forKey: Self.defaultsKey)
    }

    static func artworkURL(_ file: String?) -> URL? {
        guard let file, !file.isEmpty, !file.contains("/"),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id)
        else { return nil }
        return container.appendingPathComponent(artworkDirectory, isDirectory: true).appendingPathComponent(file)
    }

    /// Decodes an artwork file straight to at most `maxPixel` on its long
    /// side (ImageIO thumbnailing, no full-size decode) — widget extensions
    /// run under a tight memory cap.
    static func loadImage(_ file: String?, maxPixel: Int) -> UIImage? {
        guard let url = artworkURL(file),
              let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Time formatting shared by the widget and Live Activity.
enum NowPlayingFormat {
    static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    static func rate(_ r: Double) -> String {
        String(format: "%g×", (r * 100).rounded() / 100)
    }
}
