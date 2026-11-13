import SwiftUI
import UIKit
import GroupActivities

extension NowPlayingView {

    // MARK: - Track Info + Favorite

    /// SharePlay "listen together" entry point. Calls the `GroupActivity`
    /// protocol's own `activate()` directly (a core, stable part of the
    /// GroupActivities framework since its introduction) rather than a
    /// higher-level SwiftUI convenience wrapper — the OS still owns the whole
    /// activation flow (FaceTime picker, permissions, etc.) once `activate()`
    /// is called; this app only needs to hand it the activity to propose.
    /// Actual cross-device sync is handled separately by `SharePlayCoordinator`
    /// once a session starts (see that type's doc comment for why sync is
    /// message-based rather than a shared `AVPlaybackCoordinator` timeline).
    /// Requires the Group Activities capability/entitlement — see integration
    /// notes wherever project.yml/entitlements changes are tracked.
    @ViewBuilder
    var sharePlayButton: some View {
        if let song = player.currentSong {
            Button {
                Task {
                    do {
                        let activated = try await ListenTogetherActivity(songTitle: song.title, artistName: song.artist).activate()
                        if !activated {
                            // No error thrown, but the system didn't hand off to a
                            // SharePlay session — e.g. no eligible FaceTime call and
                            // the system sharing sheet was dismissed. Previously this
                            // was silently discarded (`_ = try await ...`), so tapping
                            // the button did nothing visible at all — indistinguishable
                            // from the button being broken.
                            appWarn("SharePlay activate() returned false — no session started", category: "general")
                            ToastCenter.shared.show("SharePlay unavailable — start a FaceTime call first", category: .info, icon: "shareplay")
                        }
                    } catch {
                        appWarn("SharePlay activate failed: \(error.localizedDescription)", category: "general")
                        ToastCenter.shared.show("Couldn't start SharePlay", category: .error, icon: "shareplay")
                    }
                }
            } label: {
                Image(systemName: "shareplay")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(screenStyle.controlsColor ?? AppTheme.textSecondary)
                    .frame(width: 44, height: 44)
                    .adaptiveGlass(in: Circle(), fallback: AppTheme.surface.opacity(0.5))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("SharePlay")
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
    // marquee), with the chips on their own line underneath. SharePlay
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
