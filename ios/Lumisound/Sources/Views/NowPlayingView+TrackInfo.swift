import SwiftUI
import UIKit

extension NowPlayingView {

    // MARK: - Track Info + Favorite

    /// Listen Together: opens the room (or the start / join screen).
    /// Lumisound's own rooms — any friend with the app, no FaceTime call —
    /// kept in step by the sync engine (rust/core/src/together.rs).
    @ViewBuilder
    var listenTogetherButton: some View {
        if player.currentSong != nil {
            Button {
                showListenTogetherSheet = true
            } label: {
                Image(systemName: ListenRoomService.shared.isInRoom ? "person.2.wave.2.fill" : "person.2.wave.2")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ListenRoomService.shared.isInRoom ? AppTheme.dynamicAccent : (screenStyle.controlsColor ?? AppTheme.textSecondary))
                    .frame(width: 44, height: 44)
                    .adaptiveGlass(in: Circle(), fallback: AppTheme.surface.opacity(0.5))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Listen Together")
        }
    }

    /// A small "Aria is speaking" caption shown only while `AIDJService` is
    /// mid-announcement (see that type's doc comment) — otherwise collapses
    /// to nothing so AI DJ Mode being off (the default) changes nothing
    /// about this screen's layout.
    @ViewBuilder
    var aiDJCaption: some View {
        if aiDJ.isSpeaking, let blurb = aiDJ.lastBlurb {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.caption2)
                Text(blurb)
                    .font(.caption)
                    .lineLimit(2)
            }
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(AppTheme.elevatedSurface, in: Capsule())
            .transition(.opacity.combined(with: .move(edge: .top)))
            .animation(LumiMotion.fade(0.25), value: aiDJ.isSpeaking)
        }
    }

    // 2026-09 restructure: title and artist get the full width (the format
    // and BPM chips used to share the artist's line and squeeze its
    // marquee), with the chips on their own line underneath. Listen Together
    // moved to the utility row; the heart stays here.
    var trackInfoSection: some View {
        HStack(alignment: .center, spacing: 12) {
            // Tapping the title/artist opens the format / detail sheet.
            Button {
                guard player.currentSong != nil else { return }
                selectHaptic.selectionChanged()
                showFormatInfoSheet = true
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(player.currentSong?.displayName ?? "Nothing Playing")
                        .font(screenStyle.titleFont)
                        .foregroundStyle(screenStyle.titleColor)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .contentTransition(.opacity)
                    MarqueeText(
                        text: player.currentSong?.artistName ?? "Choose a song from the Library",
                        font: screenStyle.artistFont,
                        color: screenStyle.artistColor
                    )
                    .frame(height: 22)
                    .contentTransition(.opacity)

                    trackBadges
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .animation(LumiMotion.fade(0.25), value: player.currentSong?.id)

            if let song = player.currentSong {
                let isFavorite = library.isFavorite(songID: song.id)
                Button {
                    heartHaptic.impactOccurred()
                    withAnimation(LumiMotion.snap) {
                        library.toggleFavorite(songID: song.id)
                    }
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isFavorite ? screenStyle.accentColor : (screenStyle.controlsColor ?? AppTheme.textPrimary))
                        .frame(width: 46, height: 46)
                        .adaptiveGlass(in: Circle(), fallback: AppTheme.surface.opacity(0.5))
                        .symbolReplaceTransition()
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }
        }
        // Slide-up + fade-in on track change
        .opacity(trackInfoVisible ? 1 : 0)
        .offset(y: trackInfoVisible ? 0 : 14)
        .animation(LumiMotion.settle, value: trackInfoVisible)
    }

    /// Format / BPM chips under the artist — nothing at all when neither
    /// applies, so the row doesn't reserve empty space.
    @ViewBuilder
    var trackBadges: some View {
        let bpm = LuaFeatureFlags.showBpmBadges ? player.currentSong?.bpm : nil
        let formatTag = player.currentSong?.formatTag
        if let song = player.currentSong {
            HStack(spacing: 6) {
                engineBadge(for: song)
                if let formatTag {
                    HStack(spacing: 4) {
                        if player.isUsingOpusPlayer {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(AppTheme.warning)
                        }
                        Text(formatTag)
                            .font(AppTheme.monoFont(size: 10))
                    }
                    .trackBadgeStyle()
                }
                if let bpm {
                    Text("\(Int(bpm.rounded())) BPM")
                        .font(AppTheme.monoFont(size: 10))
                        .trackBadgeStyle()
                }
                Image(systemName: "info.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
            }
            .padding(.top, 2)
        }
    }
}

extension NowPlayingView {
    /// Which audio engine is playing this track: the Lumisound Audio Engine
    /// (with a lock when the track is engine-exclusive), or the system
    /// engine (Apple Music items, or a fallback).
    @ViewBuilder
    func engineBadge(for song: Song) -> some View {
        let lumisound = player.isUsingRustEngine
        let exclusive = EngineExclusiveService.shared.isExclusive(song)
        HStack(spacing: 4) {
            Image(systemName: lumisound ? (exclusive ? "lock.fill" : "waveform") : "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .bold))
            Text(lumisound ? "LUMISOUND ENGINE" : "SYSTEM ENGINE")
                .font(AppTheme.monoFont(size: 10))
        }
        .foregroundStyle(lumisound ? screenStyle.accentColor : AppTheme.warning)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .overlay(Capsule().strokeBorder((lumisound ? screenStyle.accentColor : AppTheme.warning).opacity(0.55), lineWidth: 1))
        .fixedSize()
        .accessibilityLabel(lumisound ? (exclusive ? "Lumisound Audio Engine, exclusive" : "Lumisound Audio Engine") : "System audio engine")
    }
}

private extension View {
    func trackBadgeStyle() -> some View {
        self
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(AppTheme.textSecondary.opacity(0.35), lineWidth: 1))
            .fixedSize()
    }
}
