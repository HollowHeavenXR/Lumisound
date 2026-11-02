import SwiftUI

/// Which Gallery Background renderer `GalleryBackgroundView` shows —
/// user photos (the original, established source) or the generative
/// `SonicWallpaperView`. Read/written via `@AppStorage(storageKey)` as a
/// raw string, same convention as every other simple per-device Appearance
/// preference in this codebase.
enum GalleryBackgroundSource: String, CaseIterable, Identifiable {
    case photos
    case sonic
    case reactive

    static let storageKey = "galleryBackground_source"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photos: return "Photos"
        case .sonic: return "Sonic Wallpaper"
        case .reactive: return "Reactive Aura"
        }
    }
}

/// "Sonic Wallpaper" — a generative alternative to the photo-based Gallery
/// Background (`GalleryBackgroundView`/`BackgroundService`): instead of
/// user-supplied photos, this slowly cycles a soft gradient built from the
/// color palettes of the user's own most-played/favorited tracks' artwork,
/// reusing `ArtworkColorExtractor` — the exact same two-color-average logic
/// already driving Now Playing's ambient glow. No photos to add, no
/// storage/sync involved, and nothing ever leaves the device: it's
/// computed once per palette locally from artwork already cached by
/// `ArtworkService`.
///
/// Deliberately its own view rather than a mode bolted onto
/// `BackgroundService` — that service owns a large, established photo
/// import/sync/disk-cache pipeline (iCloud gallery sync, GIFs, thumbnails)
/// that a generative source has nothing to do with. `GalleryBackgroundView`
/// picks between the two purely by the `galleryBackground_source`
/// `@AppStorage` flag (see `AppearanceView`'s Gallery Background section).
struct SonicWallpaperView: View {
    @EnvironmentObject private var library: LibraryManager

    /// How long each palette stays on screen before switching to the next.
    private let secondsPerPalette: Double = 14

    @State private var palettes: [ArtworkPalette] = []
    @ObservedObject private var governor = HeatGovernor.shared
    @State private var visible = false

    private var frameInterval: Double {
        guard visible, governor.policy.backgroundMotion else { return 2.0 }
        return 1.0 / max(governor.policy.motionFps, 1)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: frameInterval)) { timeline in
            ZStack {
                AppTheme.background
                if let palette = currentPalette(at: timeline.date) {
                    let driftPhase = CGFloat(ArtworkClock.pingPong(timeline.date, legDuration: 20))
                    LinearGradient(
                        colors: [palette.primary, palette.secondary],
                        startPoint: UnitPoint(x: driftPhase, y: 0),
                        endPoint: UnitPoint(x: 1 - driftPhase, y: 1)
                    )
                }
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .ignoresSafeArea()
        .task { await loadPalettes() }
    }

    private func currentPalette(at date: Date) -> ArtworkPalette? {
        guard !palettes.isEmpty else { return nil }
        let elapsed = date.timeIntervalSinceReferenceDate
        let slot = Int(elapsed / secondsPerPalette) % palettes.count
        return palettes[slot]
    }

    /// Prefers favorites and most-played songs (most-played first); falls
    /// back to any songs with artwork if the user has no play history yet,
    /// so a first-run listener still sees something other than a flat
    /// background instead of an empty state.
    private func loadPalettes() async {
        let history = PlayHistoryStore.shared
        var candidates = library.allSongs.filter {
            library.favoriteSongIDs.contains($0.id) || history.playCount(for: $0.id) > 0
        }
        candidates.sort { history.playCount(for: $0.id) > history.playCount(for: $1.id) }
        if candidates.isEmpty {
            candidates = Array(library.allSongs.prefix(8))
        }

        var result: [ArtworkPalette] = []
        for song in candidates.prefix(8) {
            guard let image = await ArtworkService.shared.loadArtwork(for: song),
                  let palette = ArtworkColorExtractor.palette(from: image) else { continue }
            result.append(palette)
        }
        palettes = result
    }
}
