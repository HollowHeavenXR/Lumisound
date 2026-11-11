import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Shared between the `Lumisound` app target and the `LumisoundWidget` extension
/// target (both list this exact file in their `project.yml` sources) so the two
/// processes agree on the Live Activity's data shape without a framework.
///
/// The content is the same `NowPlayingSnapshot` the Home Screen widget reads,
/// so the Live Activity and widgets always describe the same track, artwork
/// file and timeline. Artwork itself stays in the App Group (the snapshot
/// names the per-track file), keeping the payload far under ActivityKit's
/// 4 KB limit.
struct LumisoundActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var now: NowPlayingSnapshot
    }
}
