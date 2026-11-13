import SwiftUI
import UIKit
import AVKit

extension NowPlayingView {

    // MARK: - Share content
    //
    // Sharing the current track used to hand `ShareLink` the on-disk audio
    // file URL, so the system share sheet offered to AirDrop/message the raw
    // audio file itself — surprising (and, for a downloaded stream, legally
    // murky) compared to what every other music app's share button does:
    // hand off the track's name/artist and artwork so it can be posted,
    // messaged, etc. as a reference to the song, not the song's bytes.
    // `Image` is `Transferable` out of the box (exports as image data) and
    // `SharePreview` is exactly the "title + image" shape this needs, so
    // this shares the artwork with a title/subtitle preview when artwork is
    // cached, falling back to a plain "Title — Artist" text share otherwise.
    private var shareText: String {
        guard let song = player.currentSong else { return "" }
        return song.artist.isEmpty ? song.title : "\(song.title) — \(song.artist)"
    }

    private var shareArtworkImage: Image? {
        guard let song = player.currentSong,
              let uiImage = ArtworkService.shared.artwork(for: song) else { return nil }
        return Image(uiImage: uiImage)
    }

    @ViewBuilder
    func shareLink<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        if player.currentSong != nil {
            if let image = shareArtworkImage {
                ShareLink(item: image, preview: SharePreview(shareText, image: image), label: label)
            } else {
                ShareLink(item: shareText, label: label)
            }
        }
    }

    // MARK: - Top bar
    //
    // 2026-09 restructure: the navigation bar ("Now Playing") is hidden and
    // this row is the header — display-mode pill on the left, "PLAYING FROM
    // <source>" in the middle (it used to be a separate row halfway down the
    // screen; tapping it opens the Queue panel), overflow menu on the right.
    // AirPlay moved to the utility row under the transport controls.

    var topBar: some View {
        HStack(spacing: 8) {
            displayModePill
                .frame(width: 76, alignment: .leading)

            Spacer(minLength: 4)

            Button {
                showPanel(.queue)
            } label: {
                VStack(spacing: 1) {
                    Text("PLAYING FROM")
                        .font(.system(size: 10, weight: .heavy))
                        .tracking(1.2)
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(playingFromLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the queue")

            Spacer(minLength: 4)

            overflowMenu
                .frame(width: 76, alignment: .trailing)
        }
    }

    /// Reinterpretation of the reference design's headphones/video toggle:
    /// this app has no video track, so it instead switches the hero card
    /// between the artwork display and a full-size synced-lyrics view.
    var displayModePill: some View {
        HStack(spacing: 2) {
            ForEach(NowPlayingDisplayMode.allCases) { mode in
                Button {
                    selectHaptic.selectionChanged()
                    withAnimation(LumiMotion.snap) {
                        displayMode = mode
                    }
                } label: {
                    Image(systemName: mode.iconName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(displayMode == mode ? .white : AppTheme.textSecondary)
                        .frame(width: 34, height: 28)
                        .background {
                            if displayMode == mode {
                                Capsule(style: .continuous).fill(screenStyle.accentColor)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .adaptiveGlass(in: Capsule(style: .continuous), fallback: AppTheme.surface.opacity(0.6))
        .animation(LumiMotion.snap, value: displayMode)
    }

    /// Overflow menu — sleep timer (previously only reachable once already
    /// running, via `sleepTimerPill`; this is the only way to *start* one
    /// from Now Playing), style manager, format info, and share.
    var overflowMenu: some View {
        LumiMenu {
            Button {
                navbarDisplayMode = navbarDisplayMode == .miniPlayer ? .tabs : .miniPlayer
            } label: {
                Label(
                    navbarDisplayMode == .miniPlayer ? "Switch to Tab Bar" : "Switch to Mini Player Navbar",
                    systemImage: navbarDisplayMode == .miniPlayer ? "square.grid.2x2" : "rectangle.bottomthird.inset.filled"
                )
            }
            Button {
                selectHaptic.selectionChanged()
                player.instantReplay()
            } label: {
                Label("Replay Last 15s", systemImage: "gobackward.15")
            }
            .disabled(player.currentSong == nil)
            Button {
                showSleepTimerSheet = true
            } label: {
                Label(sleepTimer.isActive ? "Edit Sleep Timer" : "Sleep Timer", systemImage: "moon.zzz.fill")
            }
            Button {
                showStemSeparationSheet = true
            } label: {
                Label("Separate Vocals / Instrumental", systemImage: "waveform.badge.minus")
            }
            .disabled(player.currentSong == nil)
            Button {
                showLyricVideoSheet = true
            } label: {
                Label("Share as Video", systemImage: "video.badge.waveform")
            }
            .disabled(player.currentSong == nil)
            Button {
                showAIDJExportSheet = true
            } label: {
                Label("Export AI DJ Set", systemImage: "mic.and.signal.meter.fill")
            }
            .disabled(aiDJ.sessionLog.isEmpty)
            Button {
                physicalGestures.shakeToSkipEnabled.toggle()
            } label: {
                Label(
                    physicalGestures.shakeToSkipEnabled ? "Shake to Skip: On" : "Shake to Skip: Off",
                    systemImage: physicalGestures.shakeToSkipEnabled ? "checkmark.circle" : "circle"
                )
            }
            Button {
                physicalGestures.coverToPauseEnabled.toggle()
            } label: {
                Label(
                    physicalGestures.coverToPauseEnabled ? "Cover to Pause: On" : "Cover to Pause: Off",
                    systemImage: physicalGestures.coverToPauseEnabled ? "checkmark.circle" : "circle"
                )
            }
            Button {
                Task {
                    if deviceSync.isHosting {
                        await deviceSync.stopHosting()
                    } else {
                        await deviceSync.startHosting()
                    }
                }
            } label: {
                Label(
                    deviceSync.isHosting ? "Stop Syncing My Devices" : "Sync My Devices",
                    systemImage: deviceSync.isHosting ? "rectangle.stack.badge.minus" : "rectangle.stack.badge.plus"
                )
            }
            // Separate from the button above on purpose: that one starts
            // broadcasting FROM this device; this one controls whether THIS
            // device is willing to auto-pick-up a session another device
            // started. A device that only ever hosts never needs this on.
            Button {
                deviceSync.autoJoinEnabled.toggle()
            } label: {
                Label(
                    deviceSync.autoJoinEnabled ? "This Device: Auto-Join On" : "This Device: Auto-Join Off",
                    systemImage: deviceSync.autoJoinEnabled ? "checkmark.circle" : "circle"
                )
            }
            Button {
                showCustomizeSheet = true
            } label: {
                Label("Customize Now Playing", systemImage: "paintbrush")
            }
            Button {
                showStyleManager = true
            } label: {
                Label("Manage Styles", systemImage: "paintpalette")
            }
            if player.currentSong?.formatTag != nil {
                Button {
                    showFormatInfoSheet = true
                } label: {
                    Label("Format Info", systemImage: "info.circle")
                }
            }
            shareLink {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            if player.currentSong != nil {
                Button {
                    showPracticeModeSheet = true
                } label: {
                    Label("Practice Mode", systemImage: "metronome")
                }
            }
            Button {
                showFocusSessionSheet = true
            } label: {
                Label("Focus Session", systemImage: "timer")
            }
            if account.isLoggedIn, player.currentSong != nil {
                Button {
                    showTransferPlaybackSheet = true
                } label: {
                    Label("Transfer Playback", systemImage: "arrow.triangle.swap")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
                .frame(width: 36, height: 36)
                .adaptiveGlass(in: Circle(), fallback: AppTheme.surface.opacity(0.6))
        }
        .accessibilityLabel("More")
    }

    // MARK: - Utility row
    //
    // One row of round glass buttons under the transport controls — the
    // Apple-Music-style bottom row: lyrics, AirPlay, SharePlay, sleep timer,
    // queue. Each used to live somewhere different (top bar, track-info row,
    // overflow menu, "Playing from" row).

    var utilityRow: some View {
        HStack(spacing: 0) {
            utilityButton(
                icon: displayMode == .lyrics ? "quote.bubble.fill" : "quote.bubble",
                label: displayMode == .lyrics ? "Show Artwork" : "Show Lyrics",
                isActive: displayMode == .lyrics
            ) {
                withAnimation(LumiMotion.snap) {
                    displayMode = displayMode == .lyrics ? .artwork : .lyrics
                }
            }
            Spacer(minLength: 0)
            AirPlayRoutePicker(
                tint: UIColor(screenStyle.controlsColor ?? AppTheme.textSecondary),
                activeTint: UIColor(screenStyle.accentColor)
            )
            .frame(width: 24, height: 24)
            .frame(width: 44, height: 44)
            .adaptiveGlass(in: Circle(), fallback: AppTheme.surface.opacity(0.5))
            .accessibilityLabel("AirPlay")
            Spacer(minLength: 0)
            sharePlayButton
            Spacer(minLength: 0)
            utilityButton(
                icon: sleepTimer.isActive ? "moon.zzz.fill" : "moon.zzz",
                label: sleepTimer.isActive ? "Edit Sleep Timer" : "Sleep Timer",
                isActive: sleepTimer.isActive
            ) {
                showSleepTimerSheet = true
            }
            Spacer(minLength: 0)
            utilityButton(
                icon: "list.bullet",
                label: "Queue",
                isActive: false,
                badge: player.upNextCount == 0 ? nil : player.upNextCount
            ) {
                showPanel(.queue)
            }
        }
        .padding(.horizontal, 6)
    }

    func utilityButton(
        icon: String,
        label: String,
        isActive: Bool,
        badge: Int? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            selectHaptic.selectionChanged()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isActive ? .white : (screenStyle.controlsColor ?? AppTheme.textSecondary))
                .frame(width: 44, height: 44)
                .background {
                    if isActive {
                        Circle().fill(screenStyle.accentColor)
                    }
                }
                .adaptiveGlass(in: Circle(), fallback: AppTheme.surface.opacity(isActive ? 0 : 0.5))
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(screenStyle.accentColor, in: Capsule())
                            .offset(x: 4, y: -2)
                    }
                }
                .symbolReplaceTransition()
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
        .animation(LumiMotion.fade(0.18), value: isActive)
    }

    /// Selects a panel and scrolls down to it (see `scrollContent`'s
    /// `panelScrollRequest` handler).
    func showPanel(_ panel: NowPlayingPanel) {
        selectHaptic.selectionChanged()
        withAnimation(LumiMotion.settle) {
            selectedPanel = panel
        }
        panelScrollRequest += 1
    }

    // MARK: - Action pills row

    /// Radio / Save-to-playlist / Share / Customize. Like moved out — the
    /// heart next to the title already does it, so the pill was a second
    /// copy of the same toggle. Still no "dislike": there's no
    /// recommendation system for one to feed.
    var actionPillsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                actionPill(icon: "dot.radiowaves.left.and.right", label: "Radio", isActive: player.autoRadioEnabled) {
                    selectHaptic.selectionChanged()
                    withAnimation(LumiMotion.snap) {
                        player.autoRadioEnabled.toggle()
                    }
                }

                if player.currentSong != nil, !library.playlists.isEmpty {
                    LumiMenu {
                        ForEach(library.playlists) { playlist in
                            Button(playlist.name) {
                                if let song = player.currentSong {
                                    library.addSong(id: song.id, toPlaylistID: playlist.id)
                                }
                            }
                        }
                    } label: {
                        actionPillLabel(icon: "plus.circle", label: "Save", isActive: false)
                    }
                }

                shareLink {
                    actionPillLabel(icon: "square.and.arrow.up", label: "Share", isActive: false)
                }

                actionPill(icon: "paintpalette", label: "Customize", isActive: false) {
                    selectHaptic.selectionChanged()
                    showCustomizeSheet = true
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    func actionPill(icon: String, label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            actionPillLabel(icon: icon, label: label, isActive: isActive)
        }
        .buttonStyle(PressableButtonStyle())
    }

    func actionPillLabel(icon: String, label: String, isActive: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
            Text(label)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(isActive ? .white : AppTheme.textPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            if isActive {
                Capsule(style: .continuous).fill(screenStyle.accentColor)
            }
        }
        .adaptiveGlass(in: Capsule(style: .continuous), fallback: AppTheme.surface.opacity(isActive ? 0 : 0.7))
        .animation(LumiMotion.fade(0.18), value: isActive)
    }
}
