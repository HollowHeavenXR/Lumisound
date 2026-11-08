import SwiftUI
import UIKit

// MARK: - LibraryScreenKit
//
// Shared structural/visual pieces for the Songs, Queue, Folders, and Folder
// Detail screens' big redesign pass — deliberately NOT touching `SongRow`/
// `SongGridCell` themselves (used across 15+ other screens and driven by the
// user's own `library_cardStyle` preference plus the Lua custom-style engine
// — silently overriding that on just these four screens would be a real
// regression for anyone who's picked a non-default row style). Everything
// here is the surrounding screen chrome instead: hero backdrops, an A-Z jump
// rail, and a breadcrumb — the pieces that make a screen's *shell* feel
// distinct without reaching into how an individual row renders.

// MARK: - HeroArtworkBackdrop

/// A big, blurred, edge-to-edge artwork backdrop for a screen header —
/// Queue's Now Playing hero and Folder Detail's header both sit on one of
/// these. Loads its own image asynchronously (mirrors `ArtworkThumbnail`'s
/// task-based pattern) so callers just hand it a `Song?` and don't need to
/// manage any loading state themselves.
struct HeroArtworkBackdrop: View {
    let song: Song?
    var height: CGFloat = 260

    @State private var image: UIImage?

    var body: some View {
        // The artwork is an OVERLAY on a full-width, fixed-height box, so it
        // never takes part in sizing. As a `scaledToFill` image with only a
        // height set, a wide (16:9 YouTube) thumbnail made this view ~680pt
        // wide; `.clipped()` hid the overflow but the layout still used the
        // full width, so the whole screen around it (buttons, grid, title)
        // was laid out wider than the phone — the "UI randomly oversized"
        // bug, depending on which song's artwork the screen showed.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 50)
                        .overlay(Color.black.opacity(0.5))
                } else {
                    LinearGradient(
                        colors: [AppTheme.dynamicAccent.opacity(0.45), AppTheme.dynamicAccentSecondary.opacity(0.25)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }
            }
            // Fades the backdrop into the screen's real background at the
            // bottom edge so content below reads as continuous, not a hard-
            // edged banner.
            .overlay {
                LinearGradient(
                    colors: [.clear, AppTheme.background],
                    startPoint: .init(x: 0.5, y: 0.35), endPoint: .bottom
                )
            }
            .clipped()
        .task(id: song?.id) {
            guard let song else { image = nil; return }
            if let cached = ArtworkService.shared.artwork(for: song) {
                image = cached
                return
            }
            image = nil
            image = await ArtworkService.shared.loadArtwork(for: song)
        }
    }
}

// MARK: - AlphabetIndexRail

/// A right-edge A-Z jump rail — tap any letter to scroll straight to that
/// section, the same idea as Contacts/Mail's index (drag-to-scrub isn't
/// supported here — see the note below on why).
///
/// Deliberately NOT built on `GeometryReader`-divided row heights + a raw
/// `DragGesture`, which an earlier version of this used: dividing the
/// overlay's available height by the letter count is fragile (a transient
/// zero/garbage size during the first layout pass collapses every letter's
/// frame to the same spot, reading as "bunched"/overlapping text), and a
/// `DragGesture(minimumDistance: 0)` attached over a mis-sized frame can
/// swallow touches meant for whatever sits above it — confirmed live: with
/// the drag-based rail, the Home/Songs/Artists pill row above the list
/// stopped responding to taps entirely. Plain `Button`s size themselves
/// naturally (no division, so no collapse case) and their hit-testing is
/// scoped exactly to each button's own small frame — there's no invisible
/// oversized gesture layer that can capture anything outside this view.
struct AlphabetIndexRail: View {
    let letters: [String]
    let onSelect: (String) -> Void

    @State private var activeLetter: String?

    var body: some View {
        VStack(spacing: 1) {
            ForEach(letters, id: \.self) { letter in
                Button {
                    activeLetter = letter
                    UISelectionFeedbackGenerator().selectionChanged()
                    onSelect(letter)
                } label: {
                    Text(letter)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(activeLetter == letter ? AppTheme.dynamicAccent : AppTheme.textSecondary)
                        .frame(width: 18, height: 12)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Groups an already-sorted list of songs into (letter, songs) buckets keyed
/// by the first character of whichever field they're sorted by — shared by
/// `SongsTab`'s list-mode sections and its index rail so both are always
/// built from the exact same grouping.
func alphabeticalSections(of songs: [Song], key: (Song) -> String) -> [(letter: String, songs: [Song])] {
    var order: [String] = []
    var buckets: [String: [Song]] = [:]
    for song in songs {
        let raw = key(song).trimmingCharacters(in: .whitespacesAndNewlines)
        let first = raw.first.map { String($0).uppercased() } ?? "#"
        let letter = first.rangeOfCharacter(from: .letters) != nil ? first : "#"
        if buckets[letter] == nil {
            buckets[letter] = []
            order.append(letter)
        }
        buckets[letter]?.append(song)
    }
    return order.map { (letter: $0, songs: buckets[$0] ?? []) }
}

// MARK: - BreadcrumbTrail

/// A short, static "parent / here" trail — this app's local-folder grouping
/// is exactly two levels deep (an "Imported Music" subfolder, then its
/// tracks; see `MusicFolderService.localFolderGroups` and
/// `LocalFolderDetailView`'s header comment), so this is intentionally not a
/// generic N-level breadcrumb component — it would be presenting navigation
/// depth the data doesn't actually have.
struct BreadcrumbTrail: View {
    let parent: String
    let current: String

    var body: some View {
        HStack(spacing: 6) {
            Text(parent)
                .foregroundStyle(AppTheme.textSecondary)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AppTheme.textSecondary.opacity(0.6))
            Text(current)
                .foregroundStyle(AppTheme.textPrimary)
                .fontWeight(.semibold)
        }
        .font(.caption)
        .lineLimit(1)
    }
}

// MARK: - ScreenStatChip

/// A small glass stat pill — "247 songs", "18h 32m" — used in the redesigned
/// headers in place of a single plain caption line, so key numbers read as
/// distinct at-a-glance facts instead of one run-on sentence.
struct ScreenStatChip: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .adaptiveGlass(in: Capsule(), fallback: AppTheme.surface.opacity(0.7))
    }
}
