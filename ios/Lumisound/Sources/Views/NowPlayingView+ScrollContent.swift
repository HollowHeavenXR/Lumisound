import SwiftUI
import UIKit

extension NowPlayingView {

    // MARK: - Scroll content

    // 2026-09 restructure. Top to bottom:
    //
    //   header        display mode · PLAYING FROM <source> · overflow
    //   hero          artwork (any built-in / custom style) or lyrics,
    //                 with a pill naming the style (opens Customize)
    //   track info    title, artist, format chips · heart
    //   timeline      the chosen seeker (+ optional counter)
    //   transport     shuffle · prev · play · next · repeat (custom-style aware)
    //   utility row   lyrics · AirPlay · SharePlay · sleep · queue
    //   actions       Radio · Save · Share · Customize
    //   panels        Controls / Sound / Queue / Lyrics / Marks, in a glass card
    //   stations      suggestion shelf
    //
    // Everything that was a style picker on the screen itself (26 artwork
    // chips, 12 seeker chips, 6 counter chips) is in the Customize sheet, and
    // the navigation bar is hidden so the header row is the top of the screen.
    var scrollContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: screenStyle.sectionSpacing) {
                    topBar

                    // No `.scrollTransition` parallax here: with it, a swipe
                    // that started anywhere in the hero didn't scroll the
                    // screen (screenshot runs 3, 5 and 6), while swipes
                    // starting below it always did.
                    heroSection
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .animation(LumiMotion.fade(0.25), value: displayMode)

                    VStack(spacing: 14) {
                        trackInfoSection
                        aiDJCaption
                        timelineSection
                    }

                    transportSection

                    utilityRow

                    ListenTogetherReactionBar()

                    actionPillsRow

                    panelCard
                        .id(Self.panelsAnchor)

                    // Contextual station ideas use the current song's
                    // metadata, plus the account's listening history and
                    // favorites.
                    StationSuggestionsSection(
                        seed: player.currentSong.map { StationSeed(song: $0) },
                        accent: screenStyle.accentColor
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                // `CustomTabBar` is composited over every tab via
                // `.safeAreaInset` on ContentView and only reserves space for
                // screens that pad for it themselves — so this does, or the
                // bottom of this screen sits under the tab bar.
                .padding(.bottom, 32 + CustomTabBar.totalHeight)
            }
            .scrollIndicators(.hidden)
            .onChange(of: panelScrollRequest) { _ in
                withAnimation(LumiMotion.settle) {
                    proxy.scrollTo(Self.panelsAnchor, anchor: .top)
                }
            }
        }
        .navigationTitle("Now Playing")
        .toolbar(.hidden, for: .navigationBar)
    }

    static let panelsAnchor = "nowPlayingPanels"

    /// The secondary-controls panels in one glass card: the picker as its
    /// header, the selected panel below. No sideways swipe to change panel:
    /// the panels are full of horizontal sliders (volume, speed, pitch, EQ)
    /// that a swipe recognizer over them would fight with.
    var panelCard: some View {
        VStack(spacing: 16) {
            panelPicker
            selectedPanelContent
                .transition(.opacity)
                .animation(LumiMotion.fade(0.18), value: selectedPanel)
        }
        .padding(12)
        .adaptiveGlass(
            in: RoundedRectangle(cornerRadius: max(screenStyle.elementCornerRadius, 24), style: .continuous),
            fallback: AppTheme.surface.opacity(0.35)
        )
    }

    /// The hero card — artwork display (default) or a full-size synced
    /// lyrics view, toggled by the top bar's display-mode pill. See
    /// `NowPlayingDisplayMode`'s doc comment for why this replaces the
    /// reference design's headphones/video toggle.
    @ViewBuilder
    var heroSection: some View {
        switch displayMode {
        case .artwork:
            artworkSection
        case .lyrics:
            NowPlayingFullLyricsHero(
                lines: lyricsLines,
                onOpenSyncEditor: { showLyricsSyncEditor = true }
            )
        }
    }

    /// Sliding-pill segmented control with an icon over each label — the
    /// accent capsule glides between panels via `matchedGeometryEffect`.
    /// (The page dots that sat under it are gone: the pill already shows
    /// which panel is selected.)
    var panelPicker: some View {
        HStack(spacing: 2) {
            ForEach(NowPlayingPanel.allCases) { panel in
                let isSelected = selectedPanel == panel
                Button {
                    selectHaptic.selectionChanged()
                    withAnimation(LumiMotion.settle) {
                        selectedPanel = panel
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: panel.iconName)
                            .font(.system(size: 14, weight: .semibold))
                        Text(panel.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(isSelected ? .white : AppTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(screenStyle.accentColor)
                                .matchedGeometryEffect(id: "panelPickerPill", in: panelPickerNamespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(AppTheme.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    @ViewBuilder
    var selectedPanelContent: some View {
        switch selectedPanel {
        case .controls:
            VStack(spacing: 20) {
                volumeSection
                playbackControlsSection
                abRepeatSection
                sleepTimerPill
                autoRadioToggle
            }
        case .sound:
            VStack(spacing: 20) {
                effectsSection
                equalizerSection
                workoutModeSection
                trackAudioSettingsSection
            }
        case .queue:
            queuePreviewSection
        case .lyrics:
            lyricsSection
        case .bookmarks:
            bookmarksSection
        }
    }
}

// MARK: - Full lyrics hero (progress-isolated, mirrors NowPlayingView+Lyrics.swift)

private struct NowPlayingFullLyricsHero: View {
    @EnvironmentObject private var progress: PlaybackProgress
    @EnvironmentObject private var player: AudioPlayerManager
    let lines: [LrcLine]
    var onOpenSyncEditor: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if lines.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 32))
                        .foregroundStyle(AppTheme.textSecondary.opacity(0.5))
                    Text("Lyrics not available")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                LyricsView(lines: lines, currentPosition: progress.position, isPlaying: player.isPlaying)
                    .frame(minHeight: 320, maxHeight: 420)
                    .clipped()

                Button(action: onOpenSyncEditor) {
                    Label("Sync Editor", systemImage: "waveform.and.mic")
                        .font(.caption)
                        .foregroundStyle(AppTheme.dynamicAccent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }
}
