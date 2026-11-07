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

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear.ignoresSafeArea()
            ProfileAccentBackgroundGlow(
                mainAccent: mainAccentColor, subAccent: subAccentColor,
                intensity: ProfileGlowIntensity.from(accentGlowIntensity)
            )

            ScrollView {
                VStack(spacing: 16) {
                    // MARK: Header — banner + avatar mirrors how this profile
                    // renders to others, using the user's own chosen
                    // main/sub accent colors.
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
                                    .fill(
                                        LinearGradient(
                                            colors: [mainAccentColor, subAccentColor],
                                            startPoint: .topLeading, endPoint: .bottomTrailing
                                        )
                                    )
                                    .overlay(
                                        Text(initials)
                                            .font(.title.bold())
                                            .foregroundStyle(.white)
                                    )
                            }
                            if isUploadingAvatar {
                                Color.black.opacity(0.45)
                                ProgressView().tint(.white)
                            }
                        }
                    } action: {
                        VStack(spacing: 8) {
                            LumiMenu {
                                Button {
                                    showAvatarPhotosPicker = true
                                } label: {
                                    Label("Photos", systemImage: "photo")
                                }
                                Button {
                                    showAvatarGifPicker = true
                                } label: {
                                    Label("GIFs", systemImage: "party.popper")
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "person.crop.circle")
                                    Text("Profile Icon")
                                        .font(AppTheme.bodyFont(size: 13))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .foregroundStyle(mainAccentColor)
                                .adaptiveGlass(
                                    tint: mainAccentColor.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                                    fallback: AppTheme.surface
                                )
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

                            HStack(spacing: 8) {
                                LumiMenu {
                                    Button {
                                        showBannerPhotosPicker = true
                                    } label: {
                                        Label("Photos", systemImage: "photo")
                                    }
                                    Button {
                                        showBannerGifPicker = true
                                    } label: {
                                        Label("GIFs", systemImage: "party.popper")
                                    }
                                } label: {
                                    HStack {
                                        if isUploadingBanner {
                                            ProgressView().tint(subAccentColor)
                                        } else {
                                            Image(systemName: "photo.on.rectangle.angled")
                                        }
                                        Text("Background Artwork")
                                            .font(AppTheme.bodyFont(size: 13))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .foregroundStyle(subAccentColor)
                                    .adaptiveGlass(
                                        tint: subAccentColor.opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                                        fallback: AppTheme.surface
                                    )
                                }
                                .disabled(isUploadingBanner)
                                .photosPicker(isPresented: $showBannerPhotosPicker, selection: $bannerPickerItem, matching: .images, photoLibrary: .shared())
                                .onChange(of: bannerPickerItem) { item in
                                    guard let item else { return }
                                    isUploadingBanner = true
                                    // `@MainActor in` is load-bearing, not
                                    // decoration: this closure isn't itself
                                    // actor-isolated, so a plain `Task { }`
                                    // here has no guaranteed home thread —
                                    // after awaiting `uploadBannerData`/the
                                    // detached GIF decode below, it can
                                    // resume on a background thread and
                                    // mutate `@State bannerImage` from off
                                    // the main thread. SwiftUI's view-graph
                                    // isn't thread-safe against that: it
                                    // doesn't crash, it silently corrupts
                                    // the *whole* screen's layout (every
                                    // card rendering as a huge blank
                                    // rounded rect) — this is what caused
                                    // the "profile stretches out" bug after
                                    // setting a banner. Same idiom this
                                    // codebase already uses everywhere else
                                    // a Task needs to safely touch UI state
                                    // from a non-isolated context.
                                    Task { @MainActor in
                                        defer { isUploadingBanner = false }
                                        if let data = try? await item.loadTransferable(type: Data.self) {
                                            await social.uploadBannerData(data)
                                            // Optimistic local update, same
                                            // reasoning as avatar upload —
                                            // don't make the user wait on a
                                            // round-trip fetch to see their
                                            // own change take effect.
                                            if data.isEmpty == false {
                                                bannerImage = isGIFData(data) ? await UIImage.gifImageAsync(data: data) : UIImage(data: data)
                                            }
                                        }
                                        bannerPickerItem = nil
                                    }
                                }

                                if bannerImage != nil {
                                    Button {
                                        Task {
                                            await social.removeBanner()
                                            bannerImage = nil
                                        }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(AppTheme.textSecondary)
                                            .padding(10)
                                            .adaptiveGlass(
                                                in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                                                fallback: AppTheme.surface
                                            )
                                    }
                                }
                            }
                        }
                    }

                    // MARK: Now Playing — live local playback state, not a
                    // fetch (this is the owner's own device).
                    if let song = player.currentSong, player.isPlaying {
                        ProfileInfoCard(title: "Listening To", icon: "waveform", tint: mainAccentColor) {
                            NowPlayingActivityRow(
                                title: song.title, artist: song.artist.isEmpty ? nil : song.artist,
                                tint: mainAccentColor, song: song
                            )
                        }
                    }

                    // MARK: Bio
                    ProfileInfoCard(title: "Bio / Status", icon: "text.quote", tint: mainAccentColor) {
                        TextField("Add a short bio or status…", text: $draftBio, axis: .vertical)
                            .lineLimit(3...6)
                            .foregroundStyle(AppTheme.textPrimary)
                            .onChange(of: draftBio) { newValue in
                                if newValue.count > 280 { draftBio = String(newValue.prefix(280)) }
                            }
                        HStack {
                            Text("**Bold**, *italic*, and [links](url) are supported.")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
                            Spacer()
                            Text("\(draftBio.count)/280")
                                .font(AppTheme.monoFont(size: 11))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }

                    // MARK: About You — pronouns + a short Discord-style
                    // custom status, distinct from the longer Bio card above.
                    ProfileInfoCard(title: "About You", icon: "person.text.rectangle", tint: mainAccentColor) {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Pronouns (e.g. she/her)", text: $pronouns)
                                .font(AppTheme.bodyFont(size: 14))
                                .foregroundStyle(AppTheme.textPrimary)
                                .onChange(of: pronouns) { newValue in
                                    if newValue.count > 30 { pronouns = String(newValue.prefix(30)) }
                                }
                            Divider().background(AppTheme.textSecondary.opacity(0.15))
                            HStack(spacing: 8) {
                                TextField("🎧", text: $statusEmoji)
                                    .font(AppTheme.bodyFont(size: 14))
                                    .frame(width: 40)
                                    .onChange(of: statusEmoji) { newValue in
                                        if newValue.count > 8 { statusEmoji = String(newValue.prefix(8)) }
                                    }
                                TextField("What are you up to?", text: $statusText)
                                    .font(AppTheme.bodyFont(size: 14))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .onChange(of: statusText) { newValue in
                                        if newValue.count > 60 { statusText = String(newValue.prefix(60)) }
                                    }
                            }
                        }
                    }

                    // MARK: Member Since
                    ProfileInfoCard(title: "Member Since", icon: "calendar", tint: subAccentColor) {
                        MemberSinceRow(memberSince: memberSince)
                    }

                    // MARK: Badges — milestone achievement chips, no privacy
                    // toggle (public flair, always shown once earned).
                    if !badges.isEmpty {
                        ProfileInfoCard(title: "Badges", icon: "rosette", tint: mainAccentColor) {
                            ProfileBadgeRow(badges: badges)
                        }
                    }

                    // MARK: Accent colors — Discord-style two-tone
                    ProfileInfoCard(title: "Profile Colors", icon: "paintpalette.fill", tint: mainAccentColor) {
                        AccentColorPickerView(title: "Main Accent", selectedHex: $mainAccentHex)
                            .padding(.vertical, 6)
                        AccentColorPickerView(title: "Sub Accent", selectedHex: $subAccentHex)
                            .padding(.vertical, 6)
                        Text("Main drives your profile's primary chrome; Sub drives secondary highlights — shown to anyone who visits your profile.")
                            .font(AppTheme.bodyFont(size: 12))
                            .foregroundStyle(AppTheme.textSecondary)

                        // MARK: Background glow intensity — how strongly the
                        // colors above wash across the WHOLE profile
                        // background (see ProfileAccentBackgroundGlow),
                        // Discord-style. Separate control from the colors
                        // themselves so someone who likes their chosen
                        // colors but finds the ambient wash too strong (or
                        // too subtle) can dial it independently.
                        Picker("Background Glow", selection: $accentGlowIntensity) {
                            ForEach([ProfileGlowIntensity.off, .subtle, .normal, .vivid], id: \.rawValue) { option in
                                Text(option.label).tag(option.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.top, 10)
                    }

                    // MARK: Card style — corner radius for every info card
                    // on the profile (Bio, Badges, Streak, etc. — see
                    // ProfileInfoCard). A local display preference, not
                    // synced/saved with the rest of this screen.
                    ProfileInfoCard(title: "Card Style", icon: "rectangle.roundedtop", tint: mainAccentColor) {
                        Picker("Card Style", selection: $profileCardCornerRadius) {
                            Text("Sharp").tag(4.0)
                            Text("Soft").tag(16.0)
                            Text("Round").tag(28.0)
                        }
                        .pickerStyle(.segmented)
                    }

                    // MARK: Avatar frame — purely cosmetic, client-rendered.
                    // Batched into the toolbar's Save button along with
                    // bio/accents/pronouns/status, not auto-saved per tap —
                    // same "pick, then Save" flow as the accent color
                    // pickers right above, so a user who taps through a few
                    // options before deciding can still back out with the
                    // system-standard "leave without saving" navigation gesture.
                    ProfileInfoCard(title: "Avatar Frame", icon: "circle.dashed", tint: subAccentColor) {
                        AvatarFramePickerView(mainTint: mainAccentColor, subTint: subAccentColor, selected: $avatarFrame)
                    }

                    // MARK: Avatar decoration — a looping animation overlaid
                    // ON TOP of the avatar itself, Discord-style, distinct
                    // from the frame above which sits AROUND it. Same
                    // "pick, then Save" flow as every other cosmetic picker
                    // on this screen.
                    ProfileInfoCard(title: "Avatar Decoration", icon: "sparkles", tint: mainAccentColor) {
                        AvatarDecorationPickerView(mainTint: mainAccentColor, subTint: subAccentColor, selected: $avatarDecoration)
                    }

                    // MARK: Profile effect — a looping animation overlaid
                    // across the whole banner, Discord-style.
                    ProfileInfoCard(title: "Profile Effect", icon: "wand.and.stars", tint: subAccentColor) {
                        ProfileEffectPickerView(mainTint: mainAccentColor, subTint: subAccentColor, selected: $profileEffect)
                    }

                    // MARK: Pinned favorite tracks
                    ProfileInfoCard(title: "Pinned Favorite Tracks", icon: "pin.fill", tint: subAccentColor) {
                        VStack(spacing: 10) {
                            ForEach(0..<5, id: \.self) { slot in
                                Button {
                                    editingSlot = slot
                                } label: {
                                    HStack {
                                        if slot < pinnedTracks.count {
                                            PinnedTrackRow(
                                                title: pinnedTracks[slot].title,
                                                artist: pinnedTracks[slot].artist,
                                                tint: subAccentColor
                                            )
                                        } else {
                                            HStack {
                                                Image(systemName: "pin.fill")
                                                    .font(.caption)
                                                    .foregroundStyle(AppTheme.textSecondary.opacity(0.4))
                                                Text("Empty slot")
                                                    .font(AppTheme.bodyFont(size: 14))
                                                    .foregroundStyle(AppTheme.textSecondary)
                                                Spacer()
                                            }
                                        }
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }
                                }
                                if slot < 4 {
                                    Divider().background(AppTheme.textSecondary.opacity(0.15))
                                }
                            }
                        }
                        Text("Pick up to 5 tracks to feature on your public profile.")
                            .font(AppTheme.bodyFont(size: 12))
                            .foregroundStyle(AppTheme.textSecondary)
                            .padding(.top, 4)
                    }

                    // MARK: Top Music showcase — auto-generated from actual
                    // listening history (same signal as the Music Match
                    // score), opt-in like Share Now Playing below. The
                    // preview always renders from `topGenres`/`topArtists`
                    // (server sends these for /me regardless of the toggle)
                    // so the owner can see exactly what turning it on would
                    // publish before committing to it.
                    ProfileInfoCard(title: "Top Music Showcase", icon: "chart.bar.fill", tint: mainAccentColor) {
                        Toggle(isOn: $showTopGenres) {
                            Label("Show Top Genres & Artists", systemImage: "chart.bar.fill")
                                .foregroundStyle(AppTheme.textPrimary)
                        }
                        .tint(mainAccentColor)
                        .onChange(of: showTopGenres) { newValue in
                            Task { await social.updateProfile(showTopGenres: newValue) }
                        }
                        if topGenres.isEmpty && topArtists.isEmpty {
                            Text("Not enough listening history yet to build a showcase.")
                                .font(AppTheme.bodyFont(size: 12))
                                .foregroundStyle(AppTheme.textSecondary)
                        } else {
                            TopMusicShowcaseRow(topGenres: topGenres, topArtists: topArtists, tint: mainAccentColor)
                                .opacity(showTopGenres ? 1 : 0.5)
                        }
                    }

                    // MARK: Listening Streak — opt-in like Top Music
                    // Showcase above; the preview always renders your own
                    // real streak regardless of the toggle, same "preview
                    // before you publish" reasoning as topGenres/topArtists.
                    if let listeningStreak {
                        ProfileInfoCard(title: "Listening Streak", icon: "flame.fill", tint: mainAccentColor) {
                            Toggle(isOn: $showListeningStats) {
                                Label("Show Listening Streak", systemImage: "flame.fill")
                                    .foregroundStyle(AppTheme.textPrimary)
                            }
                            .tint(mainAccentColor)
                            .onChange(of: showListeningStats) { newValue in
                                Task { await social.updateProfile(showListeningStats: newValue) }
                            }
                            ListeningStreakRow(streak: listeningStreak, tint: mainAccentColor)
                                .opacity(showListeningStats ? 1 : 0.5)
                        }
                    }

                    // MARK: Featured Playlist — an owner-chosen spotlight
                    // from their own server-stored playlists.
                    ProfileInfoCard(title: "Featured Playlist", icon: "music.note.list", tint: subAccentColor) {
                        if let featuredPlaylist {
                            FeaturedPlaylistRow(playlist: featuredPlaylist, tint: subAccentColor)
                        } else {
                            Text("No playlist featured yet.")
                                .font(AppTheme.bodyFont(size: 13))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        HStack(spacing: 10) {
                            Button {
                                showFeaturedPlaylistPicker = true
                            } label: {
                                Text(featuredPlaylist == nil ? "Choose Playlist" : "Change Playlist")
                                    .font(AppTheme.bodyFont(size: 13))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .foregroundStyle(subAccentColor)
                                    .adaptiveGlass(
                                        tint: subAccentColor.opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                                        fallback: AppTheme.surface
                                    )
                            }
                            if featuredPlaylist != nil {
                                Button(role: .destructive) {
                                    featuredPlaylist = nil
                                    Task { await social.setFeaturedPlaylist(playlistId: nil) }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .padding(8)
                                        .adaptiveGlass(
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                                            fallback: AppTheme.surface
                                        )
                                }
                            }
                        }
                        .padding(.top, 2)
                    }

                    // MARK: Profile Visitors — opt-out (default on), unlike
                    // the opt-in showcase/streak cards above; the preview
                    // always shows your own real stats regardless of the
                    // toggle, same "preview before you publish" reasoning.
                    ProfileInfoCard(title: "Profile Visitors", icon: "eye.fill", tint: mainAccentColor) {
                        Toggle(isOn: $showVisitorStats) {
                            Label("Show Visitor Stats", systemImage: "eye.fill")
                                .foregroundStyle(AppTheme.textPrimary)
                        }
                        .tint(mainAccentColor)
                        .onChange(of: showVisitorStats) { newValue in
                            Task { await social.updateProfile(showVisitorStats: newValue) }
                        }
                        ProfileVisitorStatsRow(visitorCount: visitorCount, recentVisitors: recentVisitors, tint: mainAccentColor)
                            .opacity(showVisitorStats ? 1 : 0.5)
                        Text("When off, no one sees your view count or recent visitors, and new visits stop being counted.")
                            .font(AppTheme.bodyFont(size: 12))
                            .foregroundStyle(AppTheme.textSecondary)
                    }

                    // MARK: Guestbook — lets the owner turn off new posts
                    // without deleting messages already left (see
                    // post_profile_comment's show_guestbook check).
                    ProfileInfoCard(title: "Guestbook", icon: "bubble.left.and.bubble.right.fill", tint: subAccentColor) {
                        Toggle(isOn: $showGuestbook) {
                            Label("Allow Guestbook Messages", systemImage: "bubble.left.and.bubble.right.fill")
                                .foregroundStyle(AppTheme.textPrimary)
                        }
                        .tint(subAccentColor)
                        .onChange(of: showGuestbook) { newValue in
                            Task { await social.updateProfile(showGuestbook: newValue) }
                        }
                        Text("When off, friends can no longer leave new messages on your profile. Messages already posted stay visible until you delete them.")
                            .font(AppTheme.bodyFont(size: 12))
                            .foregroundStyle(AppTheme.textSecondary)
                    }

                    // MARK: Privacy — now-playing sharing hook for presence
                    ProfileInfoCard(title: "Presence Privacy", icon: "eye.slash", tint: mainAccentColor) {
                        Toggle(isOn: $shareNowPlaying) {
                            Label("Share Now Playing with Friends", systemImage: "waveform")
                                .foregroundStyle(AppTheme.textPrimary)
                        }
                        .tint(mainAccentColor)
                        .onChange(of: shareNowPlaying) { newValue in
                            Task { await social.updateProfile(shareNowPlaying: newValue) }
                        }
                        Text("When off, friends only see that you're online — not what you're currently playing. This also hides you from the Friends Activity feed.")
                            .font(AppTheme.bodyFont(size: 12))
                            .foregroundStyle(AppTheme.textSecondary)
                    }

                    if let err = social.errorMessage {
                        ProfileInfoCard(tint: AppTheme.error) {
                            Label(err, systemImage: "exclamationmark.triangle")
                                .font(AppTheme.bodyFont(size: 13))
                                .foregroundStyle(AppTheme.error)
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 40)
            }
        }
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
