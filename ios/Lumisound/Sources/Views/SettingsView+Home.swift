import SwiftUI

// MARK: - Settings home (Classic / Strata)
//
// Settings as a control room instead of a tabbed list: who you are and what
// needs attention at the top, a strip of the switches people flip most, then
// nine rooms — each a focused page of cards. Search finds any setting by
// name or by what it does and jumps straight to its page.

enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case sound, library, downloads, look, notifications, sleep, devices, privacy, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sound: return "Sound"
        case .library: return "Library"
        case .downloads: return "Downloads"
        case .look: return "Look & Feel"
        case .notifications: return "Notifications"
        case .sleep: return "Sleep & Wake"
        case .devices: return "Lock Screen & Car"
        case .privacy: return "Privacy & Security"
        case .about: return "Help & About"
        }
    }

    var icon: String {
        switch self {
        case .sound: return "waveform"
        case .library: return "music.note.list"
        case .downloads: return "arrow.down.circle.fill"
        case .look: return "paintpalette.fill"
        case .notifications: return "bell.badge.fill"
        case .sleep: return "moon.stars.fill"
        case .devices: return "car.fill"
        case .privacy: return "lock.shield.fill"
        case .about: return "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .sound: return .teal
        case .library: return .pink
        case .downloads: return .cyan
        case .look: return .purple
        case .notifications: return .orange
        case .sleep: return .indigo
        case .devices: return .green
        case .privacy: return .red
        case .about: return .gray
        }
    }

    var story: String {
        switch self {
        case .sound: return "The Lumisound engine and everything it does to your music."
        case .library: return "Your collection, its health, and keeping it safe."
        case .downloads: return "Quality, speed and where new music lands."
        case .look: return "Interface, colours, glass and the navbar."
        case .notifications: return "What Lumisound may tell you about."
        case .sleep: return "Fall asleep to music, wake up to it."
        case .devices: return "The Lock Screen player, car mode and accessories."
        case .privacy: return "App lock and your account's security."
        case .about: return "Updates, help and reporting problems."
        }
    }
}

/// One searchable setting.
struct SettingsIndexEntry: Identifiable {
    let title: String
    let keywords: String
    let page: SettingsPage
    var id: String { "\(page.rawValue).\(title)" }
}

extension SettingsView {

    static let settingsIndex: [SettingsIndexEntry] = {
        func e(_ t: String, _ k: String, _ p: SettingsPage) -> SettingsIndexEntry { SettingsIndexEntry(title: t, keywords: k, page: p) }
        return [
            e("Lumisound Audio Engine", "rust engine apple", .sound),
            e("Smart Shuffle", "shuffle random", .sound),
            e("Crossfade", "fade transition blend", .sound),
            e("Smart Auto Crossfade", "dj beatmatch blend bpm", .sound),
            e("Fade Curve", "equal power linear", .sound),
            e("Gapless Playback", "gap silence", .sound),
            e("LumiEQ Equalizer", "eq bands preset tone", .sound),
            e("Auto EQ", "genre tempo eq", .sound),
            e("Loudness Match", "eq level volume", .sound),
            e("Bass Boost", "bass sub low", .sound),
            e("ReplayGain", "normalize loudness volume", .sound),
            e("Night Mode", "compression quiet", .sound),
            e("Spatial Audio", "lumispace 3d airpods head tracking room", .sound),
            e("Mono Audio", "single earbud", .sound),
            e("8D Audio", "rotate pan", .sound),
            e("Reverb", "room hall space", .sound),
            e("Default Speed", "tempo rate", .sound),
            e("Default Pitch", "key semitone", .sound),
            e("Music Haptics", "vibration feel", .sound),
            e("Skip Silent Intros", "silence trim", .sound),
            e("Scripted Visualizer (Lua)", "lua visualizer", .sound),
            e("Library Health", "metadata bitrate", .library),
            e("Duplicate Finder", "duplicates copies clean", .library),
            e("Corrupt File Finder", "broken damaged", .library),
            e("Compare Playlists", "merge overlap", .library),
            e("Storage & Cache", "space disk cache", .library),
            e("Backup & Restore", "export import", .library),
            e("Recently Deleted Playlists", "trash undo", .library),
            e("Listening Stats", "statistics plays", .library),
            e("Force Metadata Sync", "rescan tags", .library),
            e("Audio Format", "opus m4a mp3 quality", .downloads),
            e("Wi-Fi Only Downloads", "cellular data", .downloads),
            e("Subscriptions & Tracked Playlists", "auto download playlists channels", .downloads),
            e("aria2 Downloader", "connections", .downloads),
            e("Request Throttle", "sleep interval ban", .downloads),
            e("Parallel Fragments", "speed", .downloads),
            e("Download Folder", "folder location", .downloads),
            e("YouTube Cookies", "cookies age restricted", .downloads),
            e("YouTube API Key", "playlist resolve", .downloads),
            e("AcoustID API Key", "fingerprint identify", .downloads),
            e("Test Connection", "server bridge", .downloads),
            e("Interface", "classic lumen strata edition", .look),
            e("Appearance", "accent colour theme font", .look),
            e("Gallery Background", "wallpaper background", .look),
            e("Liquid Glass", "glass blur translucency", .look),
            e("Lua Theme Presets", "lua theme", .look),
            e("Navbar Mode", "tab bar mini player", .look),
            e("Hidden Tabs", "hide tabs navbar", .look),
            e("Notifications", "alerts push", .notifications),
            e("Sleep Timer", "sleep stop music", .sleep),
            e("Wake-Up Alarm", "alarm morning", .sleep),
            e("Lock Screen Player", "live activity now playing system", .devices),
            e("Car Mode", "driving car", .devices),
            e("Low Battery Alerts", "bluetooth battery", .devices),
            e("App Lock", "face id touch id passcode", .privacy),
            e("Two-Factor Authentication", "2fa totp", .privacy),
            e("Active Sessions", "devices signed in", .privacy),
            e("Change Password", "password", .privacy),
            e("Check for Updates", "update version", .about),
            e("Help & Feature Guide", "help guide", .about),
            e("Report a Bug", "bug feedback", .about),
        ]
    }()

    /// The Classic / Strata Settings screen.
    var settingsHome: some View {
        NavigationStack(path: $settingsPath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: LK.spacing) {
                    searchField
                    if settingsQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                        if updater.updateAvailable {
                            UpdateBannerView().environmentObject(updater)
                        }
                        accountCard
                        quickSwitches
                        LKSectionTitle("Rooms")
                        LKGrid {
                            ForEach(SettingsPage.allCases) { page in
                                Button {
                                    settingsPath.append(page)
                                } label: {
                                    LKTile(icon: page.icon, tint: page.tint, title: page.title,
                                           detail: tileDetail(page), badge: tileBadge(page))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Text("Lumisound \(updater.currentVersion)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 6)
                    } else {
                        searchResults
                    }
                }
                .padding(.horizontal, LK.gutter)
                .padding(.top, 4)
                .padding(.bottom, 24)
                .animation(LumiMotion.fade(0.2), value: settingsQuery.isEmpty)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: CustomTabBar.totalHeight)
            }
            .background(GalleryBackgroundView().ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: SettingsPage.self) { page in
                settingsPage(page)
            }
            .sheet(isPresented: $showLogin) {
                LoginView().environmentObject(account)
            }
            .task {
                await refreshYouTubeKeyStatus()
                startYouTubeExposureMonitor()
                await refreshAcoustIDKeyStatus()
            }
            .onDisappear {
                youtubeExposureTimer?.invalidate()
                youtubeExposureTimer = nil
            }
        }
    }

    // MARK: Home pieces

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.textSecondary)
            TextField("Search \(Self.settingsIndex.count) settings", text: $settingsQuery)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .foregroundStyle(AppTheme.textPrimary)
            if !settingsQuery.isEmpty {
                Button { settingsQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(AppTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(LKCardBackground(corner: 14))
    }

    @ViewBuilder
    private var searchResults: some View {
        let q = settingsQuery.lowercased().trimmingCharacters(in: .whitespaces)
        let hits = Self.settingsIndex.filter { $0.title.lowercased().contains(q) || $0.keywords.contains(q) || $0.page.title.lowercased().contains(q) }
        if hits.isEmpty {
            LKEmpty(icon: "magnifyingglass", title: "Nothing called \"\(settingsQuery)\"", message: "Try what it does — \"fade\", \"battery\", \"wallpaper\".")
        } else {
            LKCard(padding: 8) {
                ForEach(Array(hits.enumerated()), id: \.element.id) { i, hit in
                    Button {
                        settingsQuery = ""
                        settingsPath.append(hit.page)
                    } label: {
                        LKRow(icon: hit.page.icon, tint: hit.page.tint, title: hit.title, subtitle: hit.page.title)
                    }
                    .buttonStyle(.plain)
                    if i < hits.count - 1 { LKDivider() }
                }
            }
        }
    }

    @ViewBuilder
    private var accountCard: some View {
        if account.isLoggedIn, let user = account.currentUser {
            NavigationLink {
                AccountView().environmentObject(account).environmentObject(library)
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        if let img = account.avatarImage {
                            Image(uiImage: img).resizable().scaledToFill()
                        } else {
                            LinearGradient(colors: [AppTheme.dynamicAccent, AppTheme.accentSoft], startPoint: .topLeading, endPoint: .bottomTrailing)
                            Text(String((user.displayName ?? user.username).prefix(1)).uppercased())
                                .font(.title2.bold())
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 54, height: 54)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1.5))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(user.displayName ?? user.username)
                            .font(.headline)
                            .foregroundStyle(AppTheme.textPrimary)
                        HStack(spacing: 5) {
                            Image(systemName: account.isSyncing ? "arrow.triangle.2.circlepath" : "checkmark.icloud")
                            if account.isSyncing {
                                Text("Syncing…")
                            } else if let last = account.lastSyncDate {
                                Text("Synced \(last, style: .relative) ago")
                            } else {
                                Text("@\(user.username)")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary.opacity(0.6))
                }
                .padding(14)
                .background(LKCardBackground(tint: AppTheme.dynamicAccent))
            }
            .buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sign in to sync playlists, favorites and listening history across devices.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textPrimary)
                LKPrimaryButton(title: "Sign In or Create Account", icon: "person.badge.plus") { showLogin = true }
            }
            .padding(14)
            .background(LKCardBackground(tint: AppTheme.dynamicAccent))
        }
    }

    private var quickSwitches: some View {
        VStack(alignment: .leading, spacing: 8) {
            LKSectionTitle("Quick switches")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    QuickSwitch(title: "Crossfade", icon: "waveform.path.ecg", tint: .teal, isOn: Binding(
                        get: { player.audioSettings.crossfadeEnabled || player.audioSettings.smartCrossfadeEnabled },
                        set: { on in
                            player.audioSettings.crossfadeEnabled = on
                            if on { player.audioSettings.smartCrossfadeEnabled = false }
                            else if player.audioSettings.smartCrossfadeEnabled {
                                player.audioSettings.smartCrossfadeEnabled = false
                                AudioVisualizerService.shared.stop(for: .smartCrossfade)
                            }
                        }))
                    QuickSwitch(title: "Gapless", icon: "infinity", tint: .teal, isOn: $player.audioSettings.gaplessEnabled)
                    QuickSwitch(title: "Spatial", icon: "airpods.pro", tint: .teal, isOn: Binding(
                        get: { player.audioSettings.spatialAudioEnabled ?? false },
                        set: { on in
                            player.audioSettings.spatialAudioEnabled = on
                            if on { player.audioSettings.monoAudioEnabled = false }
                        }))
                    QuickSwitch(title: "Night Mode", icon: "moon.stars", tint: .indigo, isOn: Binding(
                        get: { player.audioSettings.nightModeEnabled ?? false },
                        set: { player.audioSettings.nightModeEnabled = $0 }))
                    QuickSwitch(title: "Wi-Fi Only", icon: "wifi", tint: .cyan, isOn: $wifiOnlyDownloadsEnabled)
                    QuickSwitch(title: "Car Mode", icon: "car.fill", tint: .green, isOn: $carModeEnabled)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func tileDetail(_ page: SettingsPage) -> String {
        let s = player.audioSettings
        switch page {
        case .sound:
            var parts: [String] = []
            if s.equalizerEnabled { parts.append(s.eqPreset.displayName) }
            if s.smartCrossfadeEnabled { parts.append("Smart fade") } else if s.crossfadeEnabled { parts.append("Crossfade \(Int(s.crossfadeDuration))s") }
            if s.spatialAudioEnabled == true { parts.append(s.lumiSpaceMode.displayName) }
            return parts.isEmpty ? "Engine defaults" : parts.joined(separator: " · ")
        case .library:
            return "\(library.allSongs.count) songs · \(library.playlists.count) playlists"
        case .downloads:
            let fmt = StreamingService.availableFormats.first { $0.value == streaming.preferredFormat }?.label ?? streaming.preferredFormat
            return wifiOnlyDownloadsEnabled ? "\(fmt) · Wi-Fi only" : fmt
        case .look:
            return "\(InterfaceEdition.current.displayName) interface"
        case .notifications:
            return !notificationService.isEnabled ? "Off" : (notificationService.isAuthorized ? "On" : "Needs access")
        case .sleep:
            return sleepTimer.isActive ? "Sleep timer running" : "Timer & alarm"
        case .devices:
            return "\(AudioPlayerManager.lockScreenPlayer.title)\(carModeEnabled ? " · Car Mode" : "")"
        case .privacy:
            return appLock.isEnabled ? "\(appLock.biometryTypeName) lock on" : "App lock off"
        case .about:
            return updater.updateAvailable ? "Update available" : "v\(updater.currentVersion)"
        }
    }

    private func tileBadge(_ page: SettingsPage) -> String? {
        switch page {
        case .about: return updater.updateAvailable ? "NEW" : nil
        case .notifications: return notificationService.isEnabled && !notificationService.isAuthorized ? "!" : nil
        case .sleep: return sleepTimer.isActive ? "ON" : nil
        default: return nil
        }
    }

    // MARK: Pages

    @ViewBuilder
    func settingsPage(_ page: SettingsPage) -> some View {
        switch page {
        case .sound: soundPage
        case .library: libraryPage
        case .downloads: downloadsPage
        case .look: lookPage
        case .notifications: NotificationsSettingsView()
        case .sleep: sleepPage
        case .devices: devicesPage
        case .privacy: privacyPage
        case .about: aboutPage
        }
    }

    private func page<Content: View>(_ p: SettingsPage, @ViewBuilder content: @escaping () -> Content) -> some View {
        LKPage(title: p.title, subtitle: p.story, icon: p.icon, tint: p.tint, showsMiniPlayer: false) {
            content()
        }
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: CustomTabBar.totalHeight) }
    }

    // MARK: Sound

    private var soundPage: some View {
        page(.sound) {
            LKCard(title: "Engine") {
                VStack(alignment: .leading, spacing: 4) { RustEngineToggleRow(player: player) }
                LKDivider()
                VStack(alignment: .leading, spacing: 4) { SmartShuffleToggleRow(player: player) }
            }
            LKCard(title: "Between songs") {
                LKToggle(icon: "waveform.path.ecg", tint: .teal, title: "Crossfade",
                         subtitle: "Fixed-length fade into the next song", isOn: $player.audioSettings.crossfadeEnabled)
                    .onChange(of: player.audioSettings.crossfadeEnabled) { on in
                        if on { player.audioSettings.smartCrossfadeEnabled = false }
                    }
                if player.audioSettings.crossfadeEnabled {
                    LKControlRow(icon: "timer", tint: .teal, title: "Fade length", value: "\(Int(player.audioSettings.crossfadeDuration)) s") {
                        Slider(value: $player.audioSettings.crossfadeDuration, in: 1...12, step: 1)
                    }
                }
                LKDivider()
                LKToggle(icon: "metronome", tint: .teal, title: "Smart Auto Crossfade",
                         subtitle: "Beat-matched, bar-aligned blends like a DJ, timed from how each song ends",
                         isOn: $player.audioSettings.smartCrossfadeEnabled)
                    .onChange(of: player.audioSettings.smartCrossfadeEnabled) { on in
                        if on {
                            player.audioSettings.crossfadeEnabled = false
                            AudioVisualizerService.shared.start(for: .smartCrossfade)
                        } else {
                            AudioVisualizerService.shared.stop(for: .smartCrossfade)
                        }
                    }
                if player.audioSettings.crossfadeActive {
                    FadeCurvePickerRow(player: player).padding(.vertical, 4)
                }
                LKDivider()
                LKToggle(icon: "infinity", tint: .teal, title: "Gapless Playback",
                         subtitle: "No silence between tracks — live albums and mixes flow", isOn: $player.audioSettings.gaplessEnabled)
                LKDivider()
                LKToggle(icon: "forward.end", tint: .teal, title: "Skip Silent Intros",
                         subtitle: "Start each song where the music begins", isOn: $silenceTrim.isEnabled)
            }
            LKCard(title: "Tone") {
                LKToggle(icon: "slider.vertical.3", tint: .teal, title: "LumiEQ",
                         subtitle: s.equalizerEnabled ? s.eqPreset.displayName + " — " + s.eqPreset.tagline : "Shape the sound with presets or your own curve",
                         isOn: $player.audioSettings.equalizerEnabled)
                if s.equalizerEnabled {
                    LKToggle(icon: "wand.and.stars", tint: .teal, title: "Auto EQ",
                             subtitle: "Picks a preset per song from its sound, genre or tempo", isOn: $player.audioSettings.autoEQEnabled)
                        .onChange(of: player.audioSettings.autoEQEnabled) { on in
                            if !on { AudioVisualizerService.shared.stop(for: .autoEQ) }
                        }
                    if s.autoEQEnabled, let reason = player.autoEQReason {
                        LKNote(reason)
                    }
                    if !s.autoEQEnabled {
                        EQPresetPickerRow(player: player).padding(.leading, 42).padding(.vertical, 4)
                    }
                    LKToggle(icon: "speaker.wave.2", tint: .teal, title: "Loudness Match",
                             subtitle: "Presets change the tone, not the volume", isOn: Binding(
                                get: { player.audioSettings.eqLoudnessMatch ?? true },
                                set: { player.audioSettings.eqLoudnessMatch = $0 }))
                }
                LKDivider()
                LKToggle(icon: "waveform.path", tint: .teal, title: "Bass Boost",
                         subtitle: "Extra weight on the 32 and 64 Hz bands", isOn: $player.audioSettings.bassBoostEnabled)
                if s.bassBoostEnabled {
                    LKControlRow(icon: "speaker.plus", tint: .teal, title: "Boost", value: String(format: "%.1f dB", s.bassBoostGain)) {
                        Slider(value: $player.audioSettings.bassBoostGain, in: 0...15, step: 0.5)
                    }
                }
                LKDivider()
                LKToggle(icon: "speaker.wave.3", tint: .teal, title: "ReplayGain",
                         subtitle: "Even out loudness between tracks", isOn: $player.audioSettings.replayGainEnabled)
                LKDivider()
                LKToggle(icon: "moon.stars", tint: .indigo, title: "Night Mode",
                         subtitle: "Gentle compression for low-volume listening", isOn: Binding(
                            get: { player.audioSettings.nightModeEnabled ?? false },
                            set: { player.audioSettings.nightModeEnabled = $0 }))
            }
            LKCard(title: "Space") {
                LKToggle(icon: "airpods.pro", tint: .teal, title: "Spatial Audio",
                         subtitle: "LumiSpace: your stereo mix on virtual speakers in a room", isOn: Binding(
                            get: { player.audioSettings.spatialAudioEnabled ?? false },
                            set: {
                                player.audioSettings.spatialAudioEnabled = $0
                                if $0 { player.audioSettings.monoAudioEnabled = false }
                            }))
                if s.spatialAudioEnabled == true {
                    LumiSpaceRoomPicker(player: player).padding(.leading, 42).padding(.bottom, 6)
                }
                LKDivider()
                LKToggle(icon: "ear", tint: .teal, title: "Mono Audio",
                         subtitle: "Both sides play the same mix — for one earbud", isOn: Binding(
                            get: { player.audioSettings.monoAudioEnabled ?? false },
                            set: {
                                player.audioSettings.monoAudioEnabled = $0
                                if $0 { player.audioSettings.spatialAudioEnabled = false }
                            }))
                LKDivider()
                LKToggle(icon: "rotate.3d", tint: .teal, title: "8D Audio",
                         subtitle: "The sound circles around you", isOn: Binding(
                            get: { player.audioSettings.eightDAudioEnabled ?? false },
                            set: { player.audioSettings.eightDAudioEnabled = $0 }))
                if s.eightDAudioEnabled == true {
                    EightDSpeedControl(player: player).padding(.leading, 42).padding(.bottom, 6)
                }
                LKDivider()
                LKToggle(icon: "circle.hexagonpath", tint: .teal, title: "Reverb",
                         subtitle: "A real sense of room around the music", isOn: $player.audioSettings.reverbEnabled)
                if s.reverbEnabled {
                    ReverbPresetPickerRow(player: player).padding(.leading, 26)
                    LKControlRow(icon: "dial.medium", tint: .teal, title: "Mix", value: "\(Int(s.reverbWetDryMix))%") {
                        Slider(value: $player.audioSettings.reverbWetDryMix, in: 0...100, step: 1)
                    }
                }
            }
            LKCard(title: "Speed & pitch", footer: "Defaults for every song; each song can still have its own in Now Playing.") {
                LKControlRow(icon: "hare", tint: .teal, title: "Speed", value: String(format: "%.2f×", s.speed)) {
                    Slider(value: $player.audioSettings.speed, in: 0.5...2.0, step: 0.05)
                }
                LKDivider()
                LKControlRow(icon: "music.quarternote.3", tint: .teal, title: "Pitch", value: pitchLabel(s.pitchSemitones)) {
                    Slider(value: $player.audioSettings.pitchSemitones, in: -12...12, step: 0.5)
                }
            }
            LKCard(title: "Feel & see") {
                LKToggle(icon: "waveform.and.mic", tint: .pink, title: "Music Haptics",
                         subtitle: MusicHapticsService.shared.isAvailable ? "Kicks, snares and bass you can feel, in time with what you hear" : "Needs a device with Core Haptics",
                         isOn: Binding(
                            get: { player.audioSettings.musicHapticsEnabled ?? false },
                            set: { player.audioSettings.musicHapticsEnabled = $0 }))
                    .disabled(!MusicHapticsService.shared.isAvailable)
                if s.musicHapticsEnabled == true, MusicHapticsService.shared.isAvailable {
                    MusicHapticsStrengthRow().padding(.leading, 42).padding(.bottom, 6)
                }
                LKDivider()
                LKLink(icon: "waveform.path.ecg.rectangle", tint: .pink, title: "Scripted Visualizer", subtitle: "Lua scripts that draw to the music") {
                    LuaVisualizerScriptsView()
                }
            }
            .animation(LumiMotion.fade(0.2), value: s)
        }
    }

    private var s: AudioSettings { player.audioSettings }

    // MARK: Library

    private var libraryPage: some View {
        page(.library) {
            HStack(spacing: 10) {
                LKStat(value: "\(library.allSongs.count)", label: "Songs", icon: "music.note", tint: .pink)
                LKStat(value: "\(library.artists.count)", label: "Artists", icon: "music.mic", tint: .pink)
            }
            HStack(spacing: 10) {
                LKStat(value: "\(library.albums.count)", label: "Albums", icon: "square.stack", tint: .pink)
                LKStat(value: "\(library.playlists.count)", label: "Playlists", icon: "music.note.list", tint: .pink)
            }
            if let error = library.errorMessage {
                LKBanner(icon: "exclamationmark.triangle.fill", text: error, tint: AppTheme.warning)
            }
            LKCard(title: "Keep it clean") {
                LKLink(icon: "heart.text.square", tint: .pink, title: "Library Health", subtitle: "Missing tags, low bitrate, duplicates and broken files at a glance") { LibraryHealthView() }
                LKDivider()
                LKLink(icon: "doc.on.doc", tint: .purple, title: "Duplicate Finder", subtitle: "Same file, source or recording — with undo") { DuplicateFilesView() }
                LKDivider()
                LKLink(icon: "exclamationmark.triangle", tint: .orange, title: "Corrupt File Finder") { CorruptFilesView() }
                LKDivider()
                LKLink(icon: "rectangle.2.swap", tint: .blue, title: "Compare Playlists", subtitle: "Overlap and merge two playlists") { PlaylistMergeToolView() }
            }
            LKCard(title: "Keep it safe") {
                LKLink(icon: "internaldrive", tint: .gray, title: "Storage & Cache") { CacheManagerView().environmentObject(cacheManager) }
                LKDivider()
                LKLink(icon: "arrow.triangle.2.circlepath", tint: .green, title: "Backup & Restore", subtitle: "Playlists and favorites to a file") { LibraryBackupView() }
                LKDivider()
                LKLink(icon: "trash", tint: .red, title: "Recently Deleted Playlists") { DeletedPlaylistsView() }
            }
            LKCard(title: "Your listening") {
                LKLink(icon: "chart.bar.fill", tint: .pink, title: "Listening Stats", subtitle: "On this device") { ListeningStatsView() }
            }
            LKCard(title: "Maintenance", footer: "Re-scans Documents (Imported Music and subfolders) and watched folders, re-reads tags and re-runs online metadata lookups for every imported track.") {
                LKButtonRow(icon: "arrow.triangle.2.circlepath", tint: .pink, title: "Force Metadata Sync",
                            subtitle: library.isForcingMetadataSync ? "Rescanning your library…" : nil,
                            busy: library.isForcingMetadataSync) {
                    Task {
                        await library.forceMetadataSync(using: folderService, currentlyPlayingID: player.currentSong?.id)
                        if let result = library.lastScanResult {
                            ToastCenter.shared.show(result, category: .success, icon: "checkmark.circle")
                            NotificationService.shared.notify(
                                title: "Library Sync Complete",
                                body: result,
                                identifier: "background-import-\(Date().timeIntervalSince1970)",
                                topic: "background_import"
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: Downloads

    private var downloadsPage: some View {
        page(.downloads) {
            LKCard(title: "Quality") {
                HStack(spacing: 12) {
                    LKIcon(symbol: "waveform", tint: .cyan)
                    AudioFormatPickerRow(streaming: streaming, tint: .cyan, hidesLabel: true)
                }
                .padding(.vertical, 4)
                LKDivider()
                LKToggle(icon: "wifi", tint: .cyan, title: "Wi-Fi Only Downloads",
                         subtitle: "Nothing downloads over cellular — including tracked playlists", isOn: $wifiOnlyDownloadsEnabled)
            }
            BackgroundDownloaderCard(streaming: streaming, library: library)
            LKCard(title: "Automatic") {
                LKLink(icon: "dot.radiowaves.left.and.right", tint: .cyan, title: "Subscriptions & Tracked Playlists",
                       subtitle: "Channels and playlists Lumisound keeps downloading for you") {
                    SubscriptionsView()
                }
            }
            LKCard(title: "Speed", footer: "Throttle pauses between requests to avoid YouTube bot checks. Parallel fragments fetch pieces of a track at once.") {
                LKToggle(icon: "bolt.horizontal.circle", tint: .yellow, title: "aria2 Downloader",
                         subtitle: ytdlpUseAria2 ? "Many connections per download — for throttled networks" : "Built-in downloader (faster on most connections)",
                         isOn: $ytdlpUseAria2)
                LKDivider()
                LKControlRow(icon: "tortoise", tint: .orange, title: "Request Throttle", value: ytdlpThrottleSeconds == 0 ? "Off" : "\(ytdlpThrottleSeconds) s") {
                    Stepper("", value: $ytdlpThrottleSeconds, in: 0...30).labelsHidden()
                }
                LKDivider()
                LKControlRow(icon: "hare", tint: .orange, title: "Parallel Fragments", value: "\(ytdlpConcurrentFragments)×") {
                    Stepper("", value: $ytdlpConcurrentFragments, in: 1...16).labelsHidden()
                }
            }
            LKCard(title: "Where downloads go", footer: "New downloads land in Imported Music/<folder>. Tracked playlists can choose their own.") {
                HStack(spacing: 12) {
                    LKIcon(symbol: "folder.fill", tint: .brown)
                    Text("Download Folder").font(AppTheme.bodyFont(size: 15)).foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    DownloadFolderPicker(folderName: $ytdlpDownloadFolder)
                }
                .padding(.vertical, 6)
            }
            if account.isLoggedIn {
                LKCard(title: "YouTube & identification") {
                    LKLink(icon: "doc.text", tint: .red, title: "YouTube Cookies", subtitle: "Age-restricted videos, fewer bot checks") { CookiesFileView() }
                    LKDivider()
                    LKLink(icon: "key", tint: .red, title: "YouTube API Key", subtitle: "Full playlist resolution", value: youtubeKeyConfig?.configured == true ? "Set" : "Not set") { YoutubeApiKeyView() }
                    LKDivider()
                    VStack(alignment: .leading, spacing: 8) { acoustIDAPIKeySection }
                        .padding(.vertical, 6)
                }
            }
            LKCard(title: "Server") {
                LKButtonRow(icon: "antenna.radiowaves.left.and.right", tint: .cyan, title: "Test Connection",
                            subtitle: showHealthResult ? (healthOK ? "Bridge is reachable" : "Bridge didn't answer") : "Checks the Lumisound bridge") {
                    Task {
                        healthOK = await streaming.checkHealth()
                        showHealthResult = true
                    }
                }
                #if DEBUG
                LKDivider()
                LKField(placeholder: "http://192.168.1.x:7333", text: Binding(get: { streaming.bridgeURL }, set: { streaming.bridgeURL = $0 }), mono: true)
                    .padding(.vertical, 4)
                LKField(placeholder: "API key (optional)", text: Binding(get: { streaming.apiKey }, set: { streaming.apiKey = $0 }), secure: true)
                #endif
            }
        }
    }

    // MARK: Look & Feel

    private var lookHideable: [(tag: Int, title: String, icon: String)] {
        [(0, "Library", "music.note.list"), (1, "Playing", "play.circle"), (2, "Queue", "list.number"),
         (3, "Cloud Services", "icloud.and.arrow.down"), (4, "Friends", "person.2.fill"), (5, "Profile", "person.crop.circle")]
    }

    private var lookHidden: Set<Int> {
        Set(navbarHiddenTabsRaw.split(separator: ",").compactMap { Int($0) })
    }

    private func lookSetHidden(_ tag: Int, _ hidden: Bool) {
        var set = lookHidden
        if hidden { set.insert(tag) } else { set.remove(tag) }
        navbarHiddenTabsRaw = set.sorted().map(String.init).joined(separator: ",")
    }

    private var lookPage: some View {
        page(.look) {
            LKGrid {
                LKTileLink(icon: "sparkles.rectangle.stack", tint: .purple, title: "Interface", detail: InterfaceEdition.current.displayName) { InterfaceEditionView() }
                LKTileLink(icon: "paintbrush.fill", tint: AppTheme.dynamicAccent, title: "Appearance", detail: "Accent, fonts, panels") { AppearanceView() }
                LKTileLink(icon: "photo.on.rectangle", tint: .blue, title: "Background", detail: "Gallery wallpaper") { BackgroundSettingsView() }
                LKTileLink(icon: "circle.hexagongrid.fill", tint: .cyan, title: "Liquid Glass", detail: "Tint and translucency") { GlassSettingsView() }
            }
            LKCard {
                LKLink(icon: "scroll.fill", tint: .orange, title: "Lua Theme Presets",
                       value: LuaThemeEngine.shared.activePresetID.flatMap { LuaPreset(rawValue: $0)?.displayName }) { LuaThemePresetsView() }
            }
            LKCard(title: "Navbar", footer: "Mini Player swaps the tab bar for artwork, a seeker and controls whenever a song is loaded.") {
                VStack(alignment: .leading, spacing: 10) {
                    LKSegmented(options: NavbarDisplayMode.allCases.map { ($0, $0.displayName) }, selection: $navbarDisplayMode, tint: .purple)
                    LKToggle(icon: "textformat", tint: .purple, title: "Tab Labels", isOn: $navbarShowTabLabels)
                    Text("Selection style").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.textSecondary)
                    LKSegmented(options: NavbarSelectionStyle.allCases.map { ($0, $0.displayName) }, selection: $navbarSelectionStyle, tint: .purple)
                }
                .padding(.vertical, 4)
            }
            LKCard(title: "Tabs in the navbar", footer: "Hidden tabs stay reachable from inside the app. Settings can't be hidden.") {
                LKGrid(columns: 3) {
                    ForEach(lookHideable, id: \.tag) { tab in
                        let shown = !lookHidden.contains(tab.tag)
                        Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            lookSetHidden(tab.tag, shown)
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: tab.icon).font(.system(size: 18, weight: .semibold))
                                Text(tab.title).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundStyle(shown ? .white : AppTheme.textSecondary)
                            .background(shown ? AnyShapeStyle(Color.purple.gradient) : AnyShapeStyle(AppTheme.elevatedSurface),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: shown ? "eye" : "eye.slash")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(5)
                                    .foregroundStyle(shown ? .white.opacity(0.8) : AppTheme.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(tab.title) tab \(shown ? "shown" : "hidden")")
                    }
                }
            }
        }
    }

    // MARK: Sleep & Wake

    private var sleepPage: some View {
        page(.sleep) {
            LKCard(title: "Sleep timer") {
                if sleepTimer.isActive {
                    SleepTimerActiveRow {
                        sleepTimer.cancel()
                        ToastCenter.shared.show("Sleep timer cancelled", category: .info, icon: "moon.zzz")
                    }
                    .padding(.vertical, 8)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(SleepTimerService.presets, id: \.seconds) { preset in
                                    Button { sleepTimer.selectedDuration = preset.seconds } label: {
                                        LKChip(title: preset.label, selected: sleepTimer.selectedDuration == preset.seconds, tint: .indigo)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        LKPrimaryButton(title: "Start Sleep Timer", icon: "moon.zzz.fill", tint: .indigo) {
                            sleepTimer.start()
                            ToastCenter.shared.show("Sleep timer started", category: .success, icon: "moon.zzz.fill")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            LKCard(title: "Morning") {
                LKLink(icon: "alarm", tint: .orange, title: "Wake-Up Alarm", subtitle: "Music that fades in to wake you") { SleepWakeAlarmView() }
            }
        }
    }

    // MARK: Lock Screen & Car

    private var devicesPage: some View {
        page(.devices) {
            LKCard(title: "Lock Screen player") {
                LockScreenPlayerRow(player: player).padding(.vertical, 6)
            }
            LKCard(title: "Driving") {
                LKToggle(icon: "car.fill", tint: .green, title: "Car Mode",
                         subtitle: carModeEnabled ? "Big-button layout, also when a car stereo connects" : "Off — no car button, no automatic switching",
                         isOn: $carModeEnabled)
            }
            LKCard(title: "Accessories", footer: "Only for accessories that report battery over standard Bluetooth LE — not AirPods or Beats.") {
                LKToggle(icon: "battery.25", tint: .green, title: "Low Battery Alerts",
                         subtitle: "Tell me when a connected accessory drops to 5 %", isOn: $bluetoothBattery.isEnabled)
            }
        }
    }

    // MARK: Privacy & Security

    private var privacyPage: some View {
        page(.privacy) {
            if appLock.biometryAvailable() {
                LKCard(title: "App lock", footer: "Lumisound asks for \(appLock.biometryTypeName) whenever it comes back from the background.") {
                    LKToggle(icon: "lock.shield", tint: .red, title: "Require \(appLock.biometryTypeName)", isOn: $appLock.isEnabled)
                }
            } else {
                LKBanner(icon: "lock.slash", text: "This device has no Face ID or Touch ID set up, so App Lock isn't available.", tint: AppTheme.warning)
            }
            if account.isLoggedIn {
                LKCard(title: "Account security") {
                    LKLink(icon: "lock.shield", tint: .red, title: "Two-Factor Authentication", value: account.isTOTPEnabled ? "On" : "Off",
                           valueTint: account.isTOTPEnabled ? AppTheme.success : nil) { TwoFactorAuthView() }
                    LKDivider()
                    LKLink(icon: "laptopcomputer.and.iphone", tint: .blue, title: "Active Sessions") { ActiveSessionsView() }
                    LKDivider()
                    LKLink(icon: "key", tint: .orange, title: "Change Password") { ChangePasswordView() }
                }
            }
        }
    }

    // MARK: Help & About

    private var aboutPage: some View {
        page(.about) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lumisound").font(.title3.bold()).foregroundStyle(AppTheme.textPrimary)
                        Text(updater.currentVersion).font(AppTheme.monoFont(size: 13)).foregroundStyle(AppTheme.textSecondary)
                    }
                    Spacer()
                    LKPill(text: updater.updateStatusText, tint: updater.updateStatusColor)
                }
                if updater.updateAvailable {
                    LKPrimaryButton(title: updater.directDownloadURL != nil ? "Download v\(updater.latestVersion ?? "") IPA" : "Download Update",
                                    icon: "arrow.down.circle.fill", tint: .green) { updater.openReleasePage() }
                }
                LKPrimaryButton(title: "Check for Updates", icon: "arrow.clockwise", tint: .green, prominent: false, busy: updater.isChecking) {
                    Task { await updater.checkForUpdates() }
                }
            }
            .padding(16)
            .background(LKCardBackground(tint: .green))
            if !WidgetDataService.shared.isAppGroupAvailable {
                LKBanner(icon: "exclamationmark.triangle.fill",
                         text: "Widgets can't read Lumisound's data: the App Group (\(AppGroup.literal)) is missing from how this build was signed. Re-sign with that App Group in the profile.",
                         tint: .orange)
            }
            LKCard(title: "Help") {
                LKLink(icon: "book.fill", tint: .blue, title: "Help & Feature Guide") { SettingsHelpView() }
                LKDivider()
                LKLink(icon: "ladybug.fill", tint: .red, title: "Report a Bug", subtitle: "Sends logs and a description") { BugReportView() }
            }
            Text("Made with a Rust audio engine and SwiftUI.")
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
                .frame(maxWidth: .infinity)
        }
    }
}

/// A capsule toggle for the home screen's quick switches.
private struct QuickSwitch: View {
    let title: String
    let icon: String
    var tint: Color
    @Binding var isOn: Bool

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(LumiMotion.snap) { isOn.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Circle()
                        .fill(isOn ? Color.white : AppTheme.textSecondary.opacity(0.35))
                        .frame(width: 8, height: 8)
                }
                Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                Text(isOn ? "On" : "Off").font(.caption2).opacity(0.8)
            }
            .frame(width: 96, alignment: .leading)
            .padding(12)
            .foregroundStyle(isOn ? .white : AppTheme.textPrimary)
            .background(isOn ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(AppTheme.surface),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(AppTheme.textPrimary.opacity(isOn ? 0 : 0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}

/// The background downloader: when it last ran, when it runs next (iOS's
/// background slot or the in-app 15-hour timer), and a button for one pass now.
struct BackgroundDownloaderCard: View {
    @ObservedObject private var store = TrackedPlaylistStore.shared
    let streaming: StreamingService
    let library: LibraryManager

    var body: some View {
        let auto = store.playlists.filter(\.isAutoDownload).count
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                LKIcon(symbol: store.isPassRunning ? "arrow.down.circle.dotted" : "arrow.down.to.line.circle.fill", tint: .cyan, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Background Downloader").font(.headline).foregroundStyle(AppTheme.textPrimary)
                    Group {
                        if store.isPassRunning {
                            Text("Downloading new tracks…")
                        } else if let last = store.lastFullRun {
                            Text("Last run \(last, style: .relative) ago")
                        } else {
                            Text("Hasn't run yet")
                        }
                    }
                    .font(.caption).foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                LKPill(text: "\(auto) auto playlist\(auto == 1 ? "" : "s")", tint: .cyan)
                if store.hasInterruptedPass { LKPill(text: "Will resume", tint: .orange) }
                if store.lastFullRun != nil, !store.isPassRunning {
                    LKPill(text: "Next ~\(store.nextScheduledRun.formatted(date: .abbreviated, time: .shortened))", tint: .gray)
                }
            }
            LKPrimaryButton(title: store.isPassRunning ? "Running…" : "Start Now", icon: "play.fill", tint: .cyan, busy: store.isPassRunning) {
                Task { await store.runPass(streaming: streaming, library: library, reason: "manual") }
            }
            .disabled(store.isPassRunning)
            Text("Runs once when you tap Start, in iOS's daily background slot, and every 15 hours while Lumisound is open. Opening the app doesn't start it, so nothing is spent when there's nothing new.")
                .font(.caption2).foregroundStyle(AppTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(LKCardBackground(tint: .cyan))
    }
}
