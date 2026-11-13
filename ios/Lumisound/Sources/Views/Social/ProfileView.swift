import PhotosUI
import SwiftUI
import UIKit

// MARK: - ProfileView
//
// The signed-in user's own public-profile editor: avatar, bio, two-tone
// accent customization (main/sub), up to 5 pinned favorite tracks, and the
// "share now playing with friends" privacy toggle that gates presence's
// now-playing line and the friends activity feed (see PresenceService /
// SocialService and the /api/social/* endpoints on the bridge).
struct ProfileView: View {
    @EnvironmentObject private var account: AccountService
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var social: SocialService
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var discordVerification: DiscordVerificationService

    @State private var draftBio: String = ""
    @State private var mainAccentHex: String? = nil
    @State private var subAccentHex: String? = nil
    // MARK: Feature: profile-customization-4
    @State private var accentGlowIntensity: String = "normal"
    @State private var shareNowPlaying: Bool = true
    @State private var pronouns: String = ""
    @State private var statusEmoji: String = ""
    @State private var statusText: String = ""
    @State private var avatarFrame: AvatarFrameStyle = .none
    // MARK: Feature: profile-customization-5
    @State private var avatarDecoration: AvatarDecorationStyle = .none
    @State private var profileEffect: ProfileEffectStyle = .none
    /// Local display preference (not synced server-side — how the cards
    /// render on THIS device), shared with `ProfileInfoCard` directly via
    /// the same `@AppStorage` key rather than round-tripping through the
    /// profile save/load network cycle like the accent-color/avatar
    /// settings above do.
    @AppStorage("profileCardCornerRadius") private var profileCardCornerRadius: Double = 16
    @State private var showTopGenres: Bool = false
    @State private var showGuestbook: Bool = true
    @State private var topGenres: [String] = []
    @State private var topArtists: [String] = []
    @State private var memberSince: String? = nil
    @State private var pinnedTracks: [PinnedTrack] = []
    // MARK: Feature: profile-customization-3
    @State private var showVisitorStats: Bool = true
    @State private var showListeningStats: Bool = false
    @State private var listeningStreak: ListeningStreak? = nil
    @State private var badges: [ProfileBadge] = []
    @State private var visitorCount: Int = 0
    @State private var recentVisitors: [ProfileVisitor] = []
    @State private var featuredPlaylist: FeaturedPlaylist? = nil
    @State private var showFeaturedPlaylistPicker = false
    @State private var isSaving = false
    @State private var editingSlot: Int? = nil // which pinned-track slot the picker sheet is editing
    @State private var photosPickerItem: PhotosPickerItem? = nil
    @State private var isUploadingAvatar = false
    @State private var bannerImage: UIImage? = nil
    @State private var bannerPickerItem: PhotosPickerItem? = nil
    @State private var isUploadingBanner = false
    @State private var showAvatarGifPicker = false
    @State private var showBannerGifPicker = false
    @State private var showAvatarPhotosPicker = false
    @State private var showBannerPhotosPicker = false
    @State private var showPublicPreview = false
    /// Guards the initial profile/banner load so it retries on every
    /// appearance until it *succeeds* (fixing data that "sometimes doesn't
    /// load" for a persistent tab), without re-firing — and clobbering
    /// unsaved edits with stale server data — every time this screen
    /// reappears after a sheet dismisses (GIF picker, banner picker, the
    /// "View as Public" preview), which is what silently discarded edits
    /// right before Save, making Save look like it did nothing.
    @State private var hasLoadedProfile = false
    @State private var hasLoadedBanner = false
    @State private var hasLoadedAvatar = false

    private var mainAccentColor: Color { SocialAccentPalette.color(for: mainAccentHex) ?? AppTheme.dynamicAccent }
    private var subAccentColor: Color { SocialAccentPalette.color(for: subAccentHex) ?? AppTheme.accentSoft }

    /// The editor's four panels.
    enum Panel: String, CaseIterable, Identifiable {
        case identity = "Identity", style = "Style", showcase = "Showcase", privacy = "Privacy"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .identity: return "person.text.rectangle"
            case .style: return "paintpalette"
            case .showcase: return "star.square.on.square"
            case .privacy: return "eye.slash"
            }
        }
    }

    @AppStorage("profileEditor.panel") private var panelRaw = Panel.identity.rawValue
    private var panel: Panel { Panel(rawValue: panelRaw) ?? .identity }
    /// What the server last confirmed, to tell whether there is anything to save.
    @State private var savedSignature = ""

    private var editSignature: String {
        [draftBio.trimmingCharacters(in: .whitespacesAndNewlines), mainAccentHex ?? "", subAccentHex ?? "", "\(shareNowPlaying)",
         pronouns.trimmingCharacters(in: .whitespacesAndNewlines), statusEmoji.trimmingCharacters(in: .whitespacesAndNewlines),
         statusText.trimmingCharacters(in: .whitespacesAndNewlines), avatarFrame.rawValue, accentGlowIntensity,
         avatarDecoration.rawValue, profileEffect.rawValue].joined(separator: "\u{1F}")
    }

    private var hasUnsavedChanges: Bool { hasLoadedProfile && editSignature != savedSignature }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear.ignoresSafeArea()
            ProfileAccentBackgroundGlow(
                mainAccent: mainAccentColor, subAccent: subAccentColor,
                intensity: ProfileGlowIntensity.from(accentGlowIntensity)
            )

            ScrollView {
                VStack(spacing: 16) {
                    // Live preview: exactly how visitors see the header.
                    ProfileHeaderCard(
                        mainAccent: mainAccentColor,
                        subAccent: subAccentColor,
                        displayName: account.currentUser?.displayName ?? account.currentUser?.username ?? "",
                        username: account.currentUser?.username ?? "",
                        isOnline: true,
                        bannerImage: bannerImage,
                        avatarFrame: avatarFrame.rawValue,
                        avatarDecoration: avatarDecoration.rawValue,
                        profileEffect: profileEffect.rawValue,
                        pronouns: pronouns,
                        statusEmoji: statusEmoji,
                        statusText: statusText,
                        discordVerified: discordVerification.isVerified,
                        discordUsername: discordVerification.discordUsername
                    ) {
                        ZStack {
                            if let img = account.avatarImage {
                                AnimatedImageView(image: img, contentMode: .scaleAspectFill)
                            } else {
                                Rectangle()
                                    .fill(LinearGradient(colors: [mainAccentColor, subAccentColor], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .overlay(Text(initials).font(.title.bold()).foregroundStyle(.white))
                            }
                            if isUploadingAvatar {
                                Color.black.opacity(0.45)
                                ProgressView().tint(.white)
                            }
                        }
                    } action: {
                        EmptyView()
                    }

                    panelPicker

                    Group {
                        switch panel {
                        case .identity: identityPanel
                        case .style: stylePanel
                        case .showcase: showcasePanel
                        case .privacy: privacyPanel
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))

                    if let err = social.errorMessage {
                        ProfileInfoCard(tint: AppTheme.error) {
                            Label(err, systemImage: "exclamationmark.triangle")
                                .font(AppTheme.bodyFont(size: 13))
                                .foregroundStyle(AppTheme.error)
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, hasUnsavedChanges ? 110 : 40)
                .animation(.spring(response: 0.35, dampingFraction: 0.86), value: panelRaw)
            }
        }
        .overlay(alignment: .bottom) {
            if hasUnsavedChanges {
                unsavedBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: hasUnsavedChanges)
        .navigationTitle("Edit Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    showPublicPreview = true
                } label: {
                    Label("View as Public", systemImage: "eye")
                }
                .disabled(account.currentUser?.id == nil)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    saveProfile()
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save").bold()
                    }
                }
                .disabled(isSaving)
            }
        }
        .sheet(isPresented: $showPublicPreview) {
            if let userId = account.currentUser?.id {
                NavigationStack {
                    PublicProfileView(userId: userId, isSelfPreview: true)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showPublicPreview = false }
                            }
                        }
                }
            }
        }
        // `.onAppear` (not `.task`, which only ever runs once for this
        // view's lifetime) — Profile is now a persistent tab rather than a
        // freshly-pushed NavigationLink destination, so its view identity
        // survives switching away and back, AND survives every sheet this
        // screen presents dismissing (GIF pickers, the "View as Public"
        // preview) — `.onAppear` fires again each time. The `hasLoaded*`
        // guards mean a failed/slow first load still retries on the next
        // appearance (fixing profile data that "sometimes doesn't load"),
        // but a load that already succeeded once never re-fires and
        // clobbers `draftBio`/accent colors/etc. with stale server data —
        // which is what silently discarded in-progress edits right before
        // the user hit Save, making Save look like it did nothing.
        .onAppear {
            if !hasLoadedProfile {
                Task {
                    await social.fetchMyProfile()
                    applyLoadedProfile()
                    if social.myProfile != nil { hasLoadedProfile = true }
                }
            }
            if !hasLoadedBanner {
                Task {
                    guard let userId = account.currentUser?.id else { return }
                    bannerImage = await SocialService.loadBanner(userId: userId)
                    hasLoadedBanner = true
                }
            }
            // Avatar is otherwise only (re)fetched from app-launch/login/
            // pull-sync call sites (see AccountService+PublicAPI.swift,
            // LumisoundApp.swift), not on navigating to this tab. That's
            // normally fine since `account.avatarImage` is shared app-wide
            // state, but landing on Profile before that app-launch fetch has
            // resolved (e.g. a fast tap right after opening the app) showed
            // nothing/stale-cache until some unrelated later event happened
            // to refresh it — this makes sure Profile always kicks its own
            // fetch too instead of depending on that timing.
            if !hasLoadedAvatar {
                Task {
                    await account.loadAvatar()
                    hasLoadedAvatar = true
                }
            }
        }
        .sheet(item: Binding(
            get: { editingSlot.map { PinnedSlot(index: $0) } },
            set: { editingSlot = $0?.index }
        )) { slot in
            PinnedTrackPickerSheet(
                currentTrack: slot.index < pinnedTracks.count ? pinnedTracks[slot.index] : nil,
                onPick: { track in
                    setPinnedSlot(slot.index, track: track)
                },
                onRemove: slot.index < pinnedTracks.count ? {
                    removePinnedSlot(slot.index)
                } : nil
            )
            .environmentObject(library)
        }
        .sheet(isPresented: $showAvatarGifPicker) {
            GifPickerSheet { data in
                Task { await account.uploadAvatarData(data) }
            }
        }
        .sheet(isPresented: $showBannerGifPicker) {
            // Matches ProfileHeaderCard's banner aspect closely enough for a
            // crop guide — it doesn't need to be pixel-exact to the current
            // device width, since the banner is still `.scaleAspectFill`ed
            // at display time either way; this just gives the user a
            // reasonable frame to compose within instead of none at all.
            GifPickerSheet(cropAspect: 2.8, isCircularGuide: false) { data in
                // Same off-main-thread `@State` mutation hazard as the
                // PhotosPicker banner path above — this closure isn't
                // actor-isolated either, so the plain `Task { }` this
                // replaced could resume on a background thread after
                // `UIImage.gifImageAsync`'s internal detached decode and
                // corrupt SwiftUI's view graph when it assigned
                // `bannerImage` from there.
                Task { @MainActor in
                    await social.uploadBannerData(data)
                    bannerImage = await UIImage.gifImageAsync(data: data)
                }
            }
        }
        .sheet(isPresented: $showFeaturedPlaylistPicker) {
            FeaturedPlaylistPickerSheet(currentPlaylistID: featuredPlaylist?.id) { picked in
                // Optimistic local update from just the summary the picker
                // already has (id/name/trackCount) — same "don't make the
                // user wait on a round trip to see their own change take
                // effect" reasoning as the avatar/banner uploads above.
                // `setFeaturedPlaylist` below refetches the full profile
                // (with real preview tracks) right after.
                featuredPlaylist = picked.map {
                    FeaturedPlaylist(id: $0.id, name: $0.name, description: nil, trackCount: $0.trackCount, previewTracks: [])
                }
                Task { await social.setFeaturedPlaylist(playlistId: picked?.id) }
            }
            .environmentObject(social)
        }
    }

    // MARK: - Panels

    private var panelPicker: some View {
        HStack(spacing: 4) {
            ForEach(Panel.allCases) { p in
                let on = panel == p
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    panelRaw = p.rawValue
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: p.icon).font(.system(size: 14, weight: .semibold))
                        Text(p.rawValue).font(.system(size: 10, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(on ? .white : AppTheme.textSecondary)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(LinearGradient(colors: [mainAccentColor, subAccentColor], startPoint: .leading, endPoint: .trailing))
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .background(LKCardBackground(corner: 16))
        .padding(.horizontal, 16)
    }

    private var unsavedBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "pencil.circle.fill").font(.system(size: 22)).foregroundStyle(mainAccentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Unsaved changes").font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.textPrimary)
                Text("Visitors still see your old profile").font(.caption2).foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            Button("Undo") { applyLoadedProfile() }
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
            Button { saveProfile() } label: {
                Group {
                    if isSaving { ProgressView().tint(.white) } else { Text("Save").bold() }
                }
                .frame(width: 64, height: 34)
                .foregroundStyle(.white)
                .background(LinearGradient(colors: [mainAccentColor, subAccentColor], startPoint: .leading, endPoint: .trailing), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(mainAccentColor.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 6)
    }

    @ViewBuilder
    private var identityPanel: some View {
        // Avatar + banner as two big tiles.
        HStack(spacing: 10) {
            LumiMenu {
                Button { showAvatarPhotosPicker = true } label: { Label("Photos", systemImage: "photo") }
                Button { showAvatarGifPicker = true } label: { Label("GIFs", systemImage: "party.popper") }
            } label: {
                mediaTile(icon: "person.crop.circle.fill", title: "Profile icon", tint: mainAccentColor, busy: isUploadingAvatar)
            }
            .photosPicker(isPresented: $showAvatarPhotosPicker, selection: $photosPickerItem, matching: .images, photoLibrary: .shared())
            .onChange(of: photosPickerItem) { item in
                guard let item else { return }
                isUploadingAvatar = true
                Task {
                    defer { isUploadingAvatar = false }
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await account.uploadAvatarData(data)
                    }
                    photosPickerItem = nil
                }
            }
            LumiMenu {
                Button { showBannerPhotosPicker = true } label: { Label("Photos", systemImage: "photo") }
                Button { showBannerGifPicker = true } label: { Label("GIFs", systemImage: "party.popper") }
                if bannerImage != nil {
                    Button(role: .destructive) {
                        Task {
                            await social.removeBanner()
                            bannerImage = nil
                        }
                    } label: { Label("Remove banner", systemImage: "trash") }
                }
            } label: {
                mediaTile(icon: "photo.on.rectangle.angled", title: "Banner", tint: subAccentColor, busy: isUploadingBanner)
            }
            .disabled(isUploadingBanner)
            .photosPicker(isPresented: $showBannerPhotosPicker, selection: $bannerPickerItem, matching: .images, photoLibrary: .shared())
            .onChange(of: bannerPickerItem) { item in
                guard let item else { return }
                isUploadingBanner = true
                // @MainActor: `bannerImage` must be set on the main thread
                // (an off-main write corrupted the whole screen's layout).
                Task { @MainActor in
                    defer { isUploadingBanner = false }
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await social.uploadBannerData(data)
                        if data.isEmpty == false {
                            bannerImage = isGIFData(data) ? await UIImage.gifImageAsync(data: data) : UIImage(data: data)
                        }
                    }
                    bannerPickerItem = nil
                }
            }
        }
        .padding(.horizontal, 16)

        if let song = player.currentSong, player.isPlaying {
            ProfileInfoCard(title: "Listening To", icon: "waveform", tint: mainAccentColor) {
                NowPlayingActivityRow(title: song.title, artist: song.artist.isEmpty ? nil : song.artist, tint: mainAccentColor, song: song)
            }
        }

        ProfileInfoCard(title: "Status", icon: "bubble.left.fill", tint: mainAccentColor) {
            HStack(spacing: 10) {
                TextField("🎧", text: $statusEmoji)
                    .font(.system(size: 22))
                    .multilineTextAlignment(.center)
                    .frame(width: 48, height: 44)
                    .background(mainAccentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onChange(of: statusEmoji) { v in if v.count > 8 { statusEmoji = String(v.prefix(8)) } }
                TextField("What are you up to?", text: $statusText)
                    .font(AppTheme.bodyFont(size: 15))
                    .foregroundStyle(AppTheme.textPrimary)
                    .onChange(of: statusText) { v in if v.count > 60 { statusText = String(v.prefix(60)) } }
            }
            TextField("Pronouns (e.g. she/her)", text: $pronouns)
                .font(AppTheme.bodyFont(size: 14))
                .foregroundStyle(AppTheme.textPrimary)
                .padding(10)
                .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onChange(of: pronouns) { v in if v.count > 30 { pronouns = String(v.prefix(30)) } }
        }

        ProfileInfoCard(title: "Bio", icon: "text.quote", tint: mainAccentColor) {
            TextField("A few lines about you and your music…", text: $draftBio, axis: .vertical)
                .lineLimit(3...6)
                .foregroundStyle(AppTheme.textPrimary)
                .onChange(of: draftBio) { v in if v.count > 280 { draftBio = String(v.prefix(280)) } }
            HStack {
                Text("**Bold**, *italic* and [links](url) work.")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
                Spacer()
                ZStack {
                    Circle().stroke(AppTheme.textSecondary.opacity(0.2), lineWidth: 2.5)
                    Circle().trim(from: 0, to: Double(draftBio.count) / 280)
                        .stroke(draftBio.count > 250 ? AppTheme.warning : mainAccentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 18, height: 18)
                Text("\(280 - draftBio.count)")
                    .font(AppTheme.monoFont(size: 11))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }

        HStack(spacing: 12) {
            ProfileInfoCard(title: "Member Since", icon: "calendar", tint: subAccentColor) {
                MemberSinceRow(memberSince: memberSince)
            }
        }
        if !badges.isEmpty {
            ProfileInfoCard(title: "Badges", icon: "rosette", tint: mainAccentColor) {
                ProfileBadgeRow(badges: badges)
            }
        }
    }

    private func mediaTile(icon: String, title: String, tint: Color, busy: Bool) -> some View {
        VStack(spacing: 8) {
            ZStack {
                if busy { ProgressView().tint(tint) } else { Image(systemName: icon).font(.system(size: 24, weight: .semibold)) }
            }
            .frame(height: 28)
            Text(title).font(.caption.weight(.semibold))
            Text("Photo or GIF").font(.caption2).opacity(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .foregroundStyle(tint)
        .adaptiveGlass(tint: tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous), fallback: AppTheme.surface)
    }

    @ViewBuilder
    private var stylePanel: some View {
        ProfileInfoCard(title: "Colors", icon: "paintpalette.fill", tint: mainAccentColor) {
            AccentColorPickerView(title: "Main Accent", selectedHex: $mainAccentHex).padding(.vertical, 6)
            AccentColorPickerView(title: "Sub Accent", selectedHex: $subAccentHex).padding(.vertical, 6)
            Text("Background glow").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.textSecondary).padding(.top, 6)
            Picker("Background Glow", selection: $accentGlowIntensity) {
                ForEach([ProfileGlowIntensity.off, .subtle, .normal, .vivid], id: \.rawValue) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
        ProfileInfoCard(title: "Card Shape", icon: "rectangle.roundedtop", tint: mainAccentColor) {
            Picker("Card Style", selection: $profileCardCornerRadius) {
                Text("Sharp").tag(4.0)
                Text("Soft").tag(16.0)
                Text("Round").tag(28.0)
            }
            .pickerStyle(.segmented)
            Text("How cards look on this device.").font(.caption2).foregroundStyle(AppTheme.textSecondary)
        }
        ProfileInfoCard(title: "Avatar Frame", icon: "circle.dashed", tint: subAccentColor) {
            AvatarFramePickerView(mainTint: mainAccentColor, subTint: subAccentColor, selected: $avatarFrame)
        }
        ProfileInfoCard(title: "Avatar Decoration", icon: "sparkles", tint: mainAccentColor) {
            AvatarDecorationPickerView(mainTint: mainAccentColor, subTint: subAccentColor, selected: $avatarDecoration)
        }
        ProfileInfoCard(title: "Profile Effect", icon: "wand.and.stars", tint: subAccentColor) {
            ProfileEffectPickerView(mainTint: mainAccentColor, subTint: subAccentColor, selected: $profileEffect)
        }
    }

    @ViewBuilder
    private var showcasePanel: some View {
        ProfileInfoCard(title: "Pinned Tracks", icon: "pin.fill", tint: subAccentColor) {
            VStack(spacing: 8) {
                ForEach(0..<5, id: \.self) { slot in
                    Button { editingSlot = slot } label: {
                        HStack(spacing: 10) {
                            Text("\(slot + 1)")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(slot < pinnedTracks.count ? .white : AppTheme.textSecondary)
                                .frame(width: 26, height: 26)
                                .background(slot < pinnedTracks.count ? AnyShapeStyle(subAccentColor) : AnyShapeStyle(AppTheme.elevatedSurface), in: Circle())
                            if slot < pinnedTracks.count {
                                PinnedTrackRow(title: pinnedTracks[slot].title, artist: pinnedTracks[slot].artist, tint: subAccentColor)
                            } else {
                                Text("Pin a track").font(AppTheme.bodyFont(size: 14)).foregroundStyle(AppTheme.textSecondary)
                                Spacer()
                            }
                            Image(systemName: slot < pinnedTracks.count ? "arrow.triangle.2.circlepath" : "plus")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        ProfileInfoCard(title: "Featured Playlist", icon: "music.note.list", tint: subAccentColor) {
            if let featuredPlaylist {
                FeaturedPlaylistRow(playlist: featuredPlaylist, tint: subAccentColor)
            } else {
                Text("Spotlight one of your playlists at the top of your profile.")
                    .font(AppTheme.bodyFont(size: 13))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            HStack(spacing: 10) {
                Button { showFeaturedPlaylistPicker = true } label: {
                    Text(featuredPlaylist == nil ? "Choose Playlist" : "Change Playlist")
                        .font(AppTheme.bodyFont(size: 13).weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundStyle(subAccentColor)
                        .adaptiveGlass(tint: subAccentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous), fallback: AppTheme.surface)
                }
                if featuredPlaylist != nil {
                    Button(role: .destructive) {
                        featuredPlaylist = nil
                        Task { await social.setFeaturedPlaylist(playlistId: nil) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .padding(11)
                            .adaptiveGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous), fallback: AppTheme.surface)
                    }
                }
            }
        }
        ProfileInfoCard(title: "Top Music", icon: "chart.bar.fill", tint: mainAccentColor) {
            Toggle(isOn: $showTopGenres) {
                Text("Show top genres & artists").foregroundStyle(AppTheme.textPrimary)
            }
            .tint(mainAccentColor)
            .onChange(of: showTopGenres) { v in Task { await social.updateProfile(showTopGenres: v) } }
            if topGenres.isEmpty && topArtists.isEmpty {
                Text("Listen a little more to build your showcase.").font(.caption).foregroundStyle(AppTheme.textSecondary)
            } else {
                TopMusicShowcaseRow(topGenres: topGenres, topArtists: topArtists, tint: mainAccentColor)
                    .opacity(showTopGenres ? 1 : 0.45)
            }
        }
        if let listeningStreak {
            ProfileInfoCard(title: "Listening Streak", icon: "flame.fill", tint: mainAccentColor) {
                Toggle(isOn: $showListeningStats) {
                    Text("Show my streak").foregroundStyle(AppTheme.textPrimary)
                }
                .tint(mainAccentColor)
                .onChange(of: showListeningStats) { v in Task { await social.updateProfile(showListeningStats: v) } }
                ListeningStreakRow(streak: listeningStreak, tint: mainAccentColor)
                    .opacity(showListeningStats ? 1 : 0.45)
            }
        }
    }

    @ViewBuilder
    private var privacyPanel: some View {
        ProfileInfoCard(title: "Who sees what", icon: "eye.slash", tint: mainAccentColor) {
            privacyToggle("Share now playing with friends",
                          detail: "Off: friends only see you're online, and you leave the Friends Activity feed.",
                          isOn: $shareNowPlaying) { v in Task { await social.updateProfile(shareNowPlaying: v) } }
            Divider().background(AppTheme.textSecondary.opacity(0.15))
            privacyToggle("Show visitor stats",
                          detail: "Off: nobody sees your view count or recent visitors, and visits stop being counted.",
                          isOn: $showVisitorStats) { v in Task { await social.updateProfile(showVisitorStats: v) } }
            ProfileVisitorStatsRow(visitorCount: visitorCount, recentVisitors: recentVisitors, tint: mainAccentColor)
                .opacity(showVisitorStats ? 1 : 0.45)
            Divider().background(AppTheme.textSecondary.opacity(0.15))
            privacyToggle("Allow guestbook messages",
                          detail: "Off: no new messages. Existing ones stay until you delete them.",
                          isOn: $showGuestbook) { v in Task { await social.updateProfile(showGuestbook: v) } }
        }
        Button { showPublicPreview = true } label: {
            Label("See my profile as a visitor", systemImage: "eye")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(mainAccentColor)
                .adaptiveGlass(tint: mainAccentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous), fallback: AppTheme.surface)
        }
        .disabled(account.currentUser?.id == nil)
        .padding(.horizontal, 16)
    }

    private func privacyToggle(_ title: String, detail: String, isOn: Binding<Bool>, onChange: @escaping (Bool) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: isOn) { Text(title).foregroundStyle(AppTheme.textPrimary) }
                .tint(mainAccentColor)
                .onChange(of: isOn.wrappedValue) { onChange($0) }
            Text(detail).font(.caption).foregroundStyle(AppTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private struct PinnedSlot: Identifiable { let index: Int; var id: Int { index } }

    private var initials: String {
        let name = account.currentUser?.displayName ?? account.currentUser?.username ?? "?"
        return String(name.prefix(1)).uppercased()
    }

    private func applyLoadedProfile() {
        guard let profile = social.myProfile else { return }
        draftBio = profile.bio ?? ""
        mainAccentHex = profile.mainAccentHex
        subAccentHex = profile.subAccentHex
        shareNowPlaying = profile.shareNowPlaying
        pronouns = profile.pronouns ?? ""
        statusEmoji = profile.statusEmoji ?? ""
        statusText = profile.statusText ?? ""
        avatarFrame = AvatarFrameStyle.from(profile.avatarFrame)
        avatarDecoration = AvatarDecorationStyle.from(profile.avatarDecoration)
        profileEffect = ProfileEffectStyle.from(profile.profileEffect)
        showTopGenres = profile.showTopGenres
        showGuestbook = profile.showGuestbook
        topGenres = profile.topGenres
        topArtists = profile.topArtists
        memberSince = profile.memberSince
        pinnedTracks = profile.pinnedTracks
        showVisitorStats = profile.showVisitorStats
        showListeningStats = profile.showListeningStats
        listeningStreak = profile.listeningStreak
        badges = profile.badges
        visitorCount = profile.visitorCount
        recentVisitors = profile.recentVisitors
        featuredPlaylist = profile.featuredPlaylist
        accentGlowIntensity = profile.accentGlowIntensity
        savedSignature = editSignature
    }

    private func setPinnedSlot(_ slot: Int, track: PinnedTrack) {
        while pinnedTracks.count <= slot {
            pinnedTracks.append(track)
        }
        pinnedTracks[slot] = track
        Task { await social.setPinnedTracks(pinnedTracks) }
    }

    private func removePinnedSlot(_ slot: Int) {
        guard slot < pinnedTracks.count else { return }
        pinnedTracks.remove(at: slot)
        Task { await social.setPinnedTracks(pinnedTracks) }
    }

    private func saveProfile() {
        guard !isSaving else { return }
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            let trimmed = draftBio.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedPronouns = pronouns.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedStatusEmoji = statusEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedStatusText = statusText.trimmingCharacters(in: .whitespacesAndNewlines)
            await social.updateProfile(
                bio: trimmed,
                mainAccentHex: mainAccentHex,
                subAccentHex: subAccentHex,
                shareNowPlaying: shareNowPlaying,
                pronouns: trimmedPronouns,
                statusEmoji: trimmedStatusEmoji,
                statusText: trimmedStatusText,
                avatarFrame: avatarFrame.rawValue,
                accentGlowIntensity: accentGlowIntensity,
                avatarDecoration: avatarDecoration.rawValue,
                profileEffect: profileEffect.rawValue
            )
            // Re-sync local @State from whatever the server actually persisted
            // (updateProfile() already refetches into social.myProfile) rather
            // than trusting the optimistic local edit — otherwise a save that
            // silently fails/partially applies leaves the screen showing a
            // value that was never actually stored, and re-entering this
            // screen later would look like "the change didn't take" with no
            // indication why.
            applyLoadedProfile()
        }
    }
}

// MARK: - PinnedTrackPickerSheet

/// Simple searchable picker over the on-device library, used to fill one of
/// the 5 pinned-track slots. Deliberately picks from `library.allSongs`
/// (what's actually on this device) rather than requiring a server-side
/// track search — a pinned track is just a display card on the profile, not
/// something that needs to be streamable from someone else's device.
private struct PinnedTrackPickerSheet: View {
    @EnvironmentObject private var library: LibraryManager
    @Environment(\.dismiss) private var dismiss

    let currentTrack: PinnedTrack?
    let onPick: (PinnedTrack) -> Void
    let onRemove: (() -> Void)?

    @State private var query = ""

    private var filteredSongs: [Song] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return library.allSongs }
        let q = query.lowercased()
        return library.allSongs.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let onRemove {
                    Button(role: .destructive) {
                        onRemove()
                        dismiss()
                    } label: {
                        Label("Remove Pinned Track", systemImage: "pin.slash")
                    }
                }
                ForEach(filteredSongs.prefix(200)) { song in
                    Button {
                        onPick(PinnedTrack(
                            sourceTrackID: song.sourceTrackID,
                            trackURL: song.url?.absoluteString,
                            title: song.title,
                            artist: song.artist.isEmpty ? nil : song.artist,
                            album: song.album.isEmpty ? nil : song.album
                        ))
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title).foregroundStyle(AppTheme.textPrimary)
                            if !song.artist.isEmpty {
                                Text(song.artist)
                                    .font(AppTheme.bodyFont(size: 12))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search your library")
            .navigationTitle("Pin a Track")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - FeaturedPlaylistPickerSheet

/// Picker over the caller's own server-stored playlists (GET
/// /user/playlists) for the Featured Playlist card — distinct from
/// `PinnedTrackPickerSheet` above, which picks from the on-device library;
/// a featured playlist has to be one the bridge itself knows about, since
/// `PUT /api/social/profile/featured-playlist` validates ownership by id.
private struct FeaturedPlaylistPickerSheet: View {
    @EnvironmentObject private var social: SocialService
    @Environment(\.dismiss) private var dismiss

    let currentPlaylistID: String?
    let onPick: (RemotePlaylistSummary?) -> Void

    @State private var playlists: [RemotePlaylistSummary] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            List {
                if currentPlaylistID != nil {
                    Button(role: .destructive) {
                        onPick(nil)
                        dismiss()
                    } label: {
                        Label("Remove Featured Playlist", systemImage: "pin.slash")
                    }
                }
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if playlists.isEmpty {
                    Text("You don't have any playlists yet.")
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    ForEach(playlists) { playlist in
                        Button {
                            onPick(playlist)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name).foregroundStyle(AppTheme.textPrimary)
                                    Text(playlist.trackCount == 1 ? "1 track" : "\(playlist.trackCount) tracks")
                                        .font(AppTheme.bodyFont(size: 12))
                                        .foregroundStyle(AppTheme.textSecondary)
                                }
                                Spacer()
                                if playlist.id == currentPlaylistID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(AppTheme.dynamicAccent)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Feature a Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                playlists = await social.fetchMyPlaylists()
                isLoading = false
            }
        }
    }
}
