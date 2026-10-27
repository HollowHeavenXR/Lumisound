import SwiftUI
import UIKit

// MARK: - Profile header components
//
// Shared building blocks for ProfileView (own, editable) and
// PublicProfileView (another user's, read-only) — a Discord-style banner
// with an overlapping avatar/status dot, plus a small family of "info card"
// sections (Bio, Now Playing, Member Since, Pinned Tracks) tinted with the
// profile owner's own main/sub accent colors so a profile actually looks
// like *theirs*, not a generic template.

// MARK: - ProfileHeaderCard

/// Gradient banner (the user's main → sub accent) with the avatar overlapping
/// its bottom edge, an optional online/offline status dot, and the
/// display name/username underneath. `action` is whatever goes right below
/// (an "Edit Profile"-style control for the owner, a friend-request control
/// for a public profile) — kept as a trailing slot rather than baked in here
/// since the two screens' actions are genuinely different shapes.
struct ProfileHeaderCard<Avatar: View, Action: View>: View {
    let mainAccent: Color
    let subAccent: Color
    let displayName: String
    let username: String
    /// `nil` hides the status dot entirely (own-profile editor doesn't need
    /// to tell you whether you're online).
    let isOnline: Bool?
    /// A user-uploaded banner image, or `nil` to fall back to the plain
    /// main/sub accent gradient. Rendered through `AnimatedImageView` (not a
    /// plain SwiftUI `Image`) so a GIF banner actually plays.
    var bannerImage: UIImage? = nil
    /// Purely cosmetic ring/glow/etc. layered around the avatar — see
    /// AvatarFrameStyle.swift. Defaults to "none" so every existing call
    /// site is unaffected.
    var avatarFrame: String = "none"
    /// Purely cosmetic looping animation overlaid ON TOP of the avatar
    /// itself — see AvatarDecorationStyle.swift. Distinct from `avatarFrame`
    /// above, which draws AROUND the avatar's edge. Defaults to "none" so
    /// every existing call site is unaffected.
    var avatarDecoration: String = "none"
    /// Purely cosmetic looping animation overlaid across the WHOLE banner —
    /// see ProfileEffectStyle.swift. Defaults to "none" so every existing
    /// call site is unaffected.
    var profileEffect: String = "none"
    /// e.g. "she/her" — shown right after the @username, Discord-style.
    var pronouns: String? = nil
    /// A short "what I'm up to" line (emoji + text), independent of the
    /// longer Bio card below — Discord custom-status style.
    var statusEmoji: String? = nil
    var statusText: String? = nil
    /// Public flair — see `DiscordVerificationService`/AccountView's own
    /// badge for the visual convention this mirrors (Discord's "blurple").
    /// Defaults false/nil so every pre-existing call site is unaffected.
    var discordVerified: Bool = false
    var discordUsername: String? = nil

    private let avatar: Avatar
    private let action: Action

    init(
        mainAccent: Color,
        subAccent: Color,
        displayName: String,
        username: String,
        isOnline: Bool?,
        bannerImage: UIImage? = nil,
        avatarFrame: String = "none",
        avatarDecoration: String = "none",
        profileEffect: String = "none",
        pronouns: String? = nil,
        statusEmoji: String? = nil,
        statusText: String? = nil,
        discordVerified: Bool = false,
        discordUsername: String? = nil,
        @ViewBuilder avatar: () -> Avatar,
        @ViewBuilder action: () -> Action
    ) {
        self.mainAccent = mainAccent
        self.subAccent = subAccent
        self.displayName = displayName
        self.username = username
        self.isOnline = isOnline
        self.bannerImage = bannerImage
        self.avatarFrame = avatarFrame
        self.avatarDecoration = avatarDecoration
        self.profileEffect = profileEffect
        self.pronouns = pronouns
        self.statusEmoji = statusEmoji
        self.statusText = statusText
        self.discordVerified = discordVerified
        self.discordUsername = discordUsername
        self.avatar = avatar()
        self.action = action()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let bannerImage {
                    AnimatedImageView(image: bannerImage, contentMode: .scaleAspectFill)
                } else {
                    LinearGradient(
                        colors: [mainAccent, subAccent],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }
            }
            // `AnimatedImageView` (a `UIViewRepresentable`) has no shape-like
            // "expand to fill proposed space" behavior the way `LinearGradient`
            // does — without this it would size to the banner image's own
            // intrinsic pixel dimensions instead of stretching edge-to-edge.
            .frame(maxWidth: .infinity)
            .overlay(
                // A soft bottom fade so a light avatar-ring stroke and the
                // name text underneath both stay legible against any accent
                // pair or banner image, including busy/light ones.
                LinearGradient(colors: [.clear, .black.opacity(0.32)], startPoint: .top, endPoint: .bottom)
            )
            .overlay(
                // Discord-style "Profile Effect" — a looping animation across
                // the whole banner. Layered here (before the clipShape below)
                // so it gets clipped to the same rounded-rect banner shape
                // instead of bleeding past its corners.
                ProfileEffectOverlay(style: ProfileEffectStyle.from(profileEffect), mainTint: mainAccent, subTint: subAccent)
            )
            .frame(height: 108)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            // `.overlay` composites on top WITHOUT being clipped by the
            // banner's own clipShape above — this is what lets the avatar
            // hang half below the banner's rounded rect instead of being
            // cut off at its edge.
            .overlay(alignment: .bottomLeading) {
                ZStack(alignment: .bottomTrailing) {
                    // Frame decoration and avatar must be centered on each
                    // other regardless of the frame's own (larger) size —
                    // nested in their own default-aligned ZStack rather than
                    // sharing the outer .bottomTrailing alignment, which used
                    // to pin their bottom-trailing corners together instead
                    // and visibly offset every frame preset from the avatar.
                    ZStack {
                        AvatarFrameOverlay(style: AvatarFrameStyle.from(avatarFrame), diameter: 84, mainTint: mainAccent, subTint: subAccent)
                        avatar
                            .frame(width: 84, height: 84)
                            .clipShape(Circle())
                            // Was a plain `AppTheme.background`-colored ring —
                            // purely a cutout border with zero connection to the
                            // profile's own chosen accent. Whenever a banner
                            // image is set (the common case, and this user's
                            // case specifically), the banner covers the
                            // main/sub gradient below entirely, so this ring
                            // was the *only* place `mainAccent` could show up
                            // in the header at all — and it wasn't using it.
                            .overlay(Circle().stroke(mainAccent, lineWidth: 4))
                            .shadow(color: .black.opacity(0.28), radius: 6, x: 0, y: 3)
                        // Discord-style "Avatar Decoration" — layered AFTER
                        // (on top of) the avatar image itself, unlike
                        // AvatarFrameOverlay above which sits around/behind it.
                        AvatarDecorationOverlay(style: AvatarDecorationStyle.from(avatarDecoration), diameter: 84, mainTint: mainAccent, subTint: subAccent)
                    }
                    if let isOnline {
                        Circle()
                            .fill(isOnline ? AppTheme.success : AppTheme.textSecondary.opacity(0.5))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().stroke(AppTheme.background, lineWidth: 3))
                    }
                }
                .padding(.leading, 16)
                .offset(y: 40)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(displayName)
                        .font(.title2.bold())
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    if discordVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color(red: 0.345, green: 0.396, blue: 0.949))
                    }
                }
                HStack(spacing: 6) {
                    Text("@\(username)")
                        .font(AppTheme.bodyFont(size: 13))
                        .foregroundStyle(AppTheme.textSecondary)
                    if let pronouns, !pronouns.isEmpty {
                        Text("· \(pronouns)")
                            .font(AppTheme.bodyFont(size: 13))
                            .foregroundStyle(AppTheme.textSecondary.opacity(0.8))
                    }
                }
                if discordVerified, let discordUsername, !discordUsername.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(red: 0.345, green: 0.396, blue: 0.949))
                        Text(discordUsername)
                            .font(AppTheme.bodyFont(size: 12))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                if let statusText, !statusText.isEmpty {
                    HStack(spacing: 4) {
                        if let statusEmoji, !statusEmoji.isEmpty {
                            Text(statusEmoji)
                        }
                        Text(statusText)
                            .font(AppTheme.bodyFont(size: 12))
                            .foregroundStyle(AppTheme.textPrimary.opacity(0.85))
                            .lineLimit(1)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.leading, 32)
            .padding(.top, 48)
            .padding(.trailing, 16)

            action
                .padding(.horizontal, 16)
                .padding(.top, 14)
        }
    }
}

// MARK: - ProfileAccentBackgroundGlow

/// A soft ambient wash of the profile's own main/sub accent colors bleeding
/// down from the banner into the rest of the screen — Discord-style "your
/// profile theme color tints the whole page," rather than the screen just
/// staying plain black below the banner regardless of what accent colors
/// were actually chosen. Meant to sit as the base layer of the screen's
/// `ZStack`, behind the scrollable content, on both `ProfileView` (own,
/// editable) and `PublicProfileView` (another user's) so the effect is
/// consistent everywhere a profile is shown.
///
/// BUG FIXED: both call sites wrapped this in a plain `ZStack { ... }` with
/// no explicit alignment — `ZStack`'s default alignment is `.center`, so
/// this fixed-height band was being centered vertically in the full screen
/// instead of anchored to the top the way a top-to-bottom gradient (accent
/// color at `startPoint: .top`) requires to read correctly. The visible
/// result was a colored band floating in the middle of the screen with
/// plain background above AND below it — neither the top (behind the
/// banner, where the color should be strongest) nor the bottom actually
/// showed any wash. Both call sites now pass `alignment: .top` to their
/// `ZStack`. The gradient itself is also taller now with more, closer
/// stops so the blend reaches further down the (often long, scrollable)
/// profile content instead of cutting to fully transparent after a fixed
/// 480pt, which — even with top alignment — would still have looked like
/// color only near the very top and nothing for the rest of the page.
/// Feature: profile-customization-4 — user-chosen strength for
/// `ProfileAccentBackgroundGlow`'s wash, server-validated against this same
/// allowlist (see main.py's `_valid_glow_intensity`). `multiplier` scales
/// every stop's opacity uniformly rather than swapping in a whole separate
/// stop list, so the color balance/falloff shape stays identical across
/// intensities — only how strong it reads changes.
enum ProfileGlowIntensity: String {
    case off, subtle, normal, vivid

    /// NOT `init(rawValue:)` — overloading the synthesized `init?(rawValue:
    /// String)` with a second initializer differing only in the parameter
    /// being `String?` is ambiguous-by-conversion at call sites that pass a
    /// non-optional `String` (both become viable — the exact-match failable
    /// one and this one via implicit optional-promotion — and Swift picks
    /// the exact match), silently resolving to the WRONG (optional-
    /// returning) initializer there instead of this one. A distinctly-named
    /// static factory sidesteps the overload resolution entirely.
    static func from(_ rawValue: String?) -> ProfileGlowIntensity {
        ProfileGlowIntensity(rawValue: rawValue ?? "normal") ?? .normal
    }

    var multiplier: Double {
        switch self {
        case .off:     return 0
        case .subtle:  return 0.55
        case .normal:  return 1.0
        case .vivid:   return 1.55
        }
    }

    var label: String {
        switch self {
        case .off:     return "Off"
        case .subtle:  return "Subtle"
        case .normal:  return "Normal"
        case .vivid:   return "Vivid"
        }
    }
}

struct ProfileAccentBackgroundGlow: View {
    let mainAccent: Color
    let subAccent: Color
    var intensity: ProfileGlowIntensity = .normal

    var body: some View {
        let m = intensity.multiplier
        GeometryReader { proxy in
            LinearGradient(
                colors: [
                    mainAccent.opacity(0.55 * m),
                    mainAccent.opacity(0.34 * m),
                    subAccent.opacity(0.26 * m),
                    subAccent.opacity(0.16 * m),
                    subAccent.opacity(0.07 * m),
                    .clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: proxy.size.width, height: max(700, proxy.size.height * 0.85))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Heavily blurred so this reads as an ambient color wash rather
        // than a hard-edged colored rectangle sitting behind the content —
        // the same "glow" treatment already used for the mini-player's
        // play button shadow and similar accent-colored chrome elsewhere.
        .blur(radius: 60)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - ProfileInfoCard

/// A single titled "section card" — Bio, Now Playing, Member Since, Pinned
/// Tracks, Presence Privacy all render as one of these, tinted with the
/// profile's own accent so every section reads as part of the same profile
/// rather than a plain system list. Uses the same `adaptiveGlass` material
/// the rest of the redesigned app already uses for floating chrome.
struct ProfileInfoCard<Content: View>: View {
    var title: String? = nil
    var icon: String? = nil
    let tint: Color
    private let content: Content

    /// "Open up ALOT more customization to the profiles" — one global,
    /// user-chosen corner radius for every info card on the profile
    /// (Bio, Badges, Streak, About You, etc. all route through this same
    /// type), set from ProfileView's "Card Style" picker. `@AppStorage`
    /// directly on a leaf component (rather than threading a parameter
    /// through every one of this type's ~15 call sites) is the same
    /// "shared key, read wherever it's needed" pattern already used for
    /// Navbar Mode across CustomTabBar/MiniPlayerBar/Settings/Now Playing.
    @AppStorage("profileCardCornerRadius") private var cornerRadius: Double = 16

    init(title: String? = nil, icon: String? = nil, tint: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 6) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tint)
                    }
                    Text(title.uppercased())
                        .font(AppTheme.bodyFont(size: 11))
                        .foregroundStyle(AppTheme.textSecondary)
                        .kerning(0.8)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveGlass(
            tint: tint.opacity(0.14),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            fallback: AppTheme.surface
        )
        .padding(.horizontal, 16)
    }
}

// MARK: - NowPlayingActivityRow

/// "Listening to Lumisound" row — reused by both the owner's live
/// `player.currentSong` and a friend's fetched `SocialPresence`, so the same
/// visual shows up whether the data came from local playback state or a
/// network fetch.
struct NowPlayingActivityRow: View {
    let title: String
    let artist: String?
    let tint: Color
    /// The actual `Song` being played, when known — lets this row show real
    /// artwork via `ArtworkThumbnail` instead of a generic note icon. Only
    /// available on the owner's own profile (`player.currentSong`).
    var song: Song? = nil
    /// Remote thumbnail URL from a friend's/visitor's `SocialPresence` (see
    /// `now_playing_artwork_url` — PresenceService.sendHeartbeat derives it
    /// from the reporting device's own `Song.youtubeThumbnailURL`). Only
    /// consulted when `song` is nil, since a locally-known `Song` always has
    /// a better (cached, possibly non-YouTube, possibly higher-res) source.
    var artworkURL: URL? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let song {
                ArtworkThumbnail(song: song, size: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if let artworkURL {
                CachedAsyncImage(url: artworkURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(tint.opacity(0.2))
                            Image(systemName: "music.note")
                                .foregroundStyle(tint)
                        }
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint.opacity(0.2))
                    Image(systemName: "music.note")
                        .foregroundStyle(tint)
                }
                .frame(width: 40, height: 40)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppTheme.bodyFont(size: 14))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                if let artist, !artist.isEmpty {
                    Text(artist)
                        .font(AppTheme.bodyFont(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "waveform")
                .font(.caption)
                .foregroundStyle(tint)
        }
    }
}

// MARK: - MemberSinceRow

/// "Member Since" row — formats the ISO8601 `member_since` timestamp the
/// bridge derives from `ios_users.created_at` (account creation, not the
/// lazily-created social-profile row) into a long localized date.
struct MemberSinceRow: View {
    let memberSince: String?

    private var formatted: String {
        guard let memberSince, let date = parseServerDate(memberSince) else {
            return "Unknown"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .foregroundStyle(AppTheme.textSecondary)
            Text(formatted)
                .font(AppTheme.bodyFont(size: 13))
                .foregroundStyle(AppTheme.textPrimary)
        }
    }
}

// MARK: - MusicCompatibilityRow

/// "Music Match" score row — a percentage bar plus a couple of rows of
/// shared-artist/shared-genre chips, backed by GET
/// /api/social/compatibility/{user_id}. Friends-only server-side (see
/// main.py's `social_compatibility`), so this is only ever shown once the
/// viewed profile is confirmed a friend.
struct MusicCompatibilityRow: View {
    let compatibility: MusicCompatibility
    let tint: Color

    var body: some View {
        if compatibility.insufficientData {
            Text("Not enough listening history yet to compute a match.")
                .font(AppTheme.bodyFont(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(compatibility.score)%")
                        .font(.title2.bold())
                        .foregroundStyle(tint)
                    Text("match")
                        .font(AppTheme.bodyFont(size: 13))
                        .foregroundStyle(AppTheme.textSecondary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(tint.opacity(0.15))
                        Capsule().fill(tint)
                            .frame(width: geo.size.width * CGFloat(min(max(compatibility.score, 0), 100)) / 100)
                    }
                }
                .frame(height: 8)

                if !compatibility.sharedArtists.isEmpty {
                    CompatibilityChipRow(label: "Shared Artists", items: compatibility.sharedArtists, tint: tint)
                }
                if !compatibility.sharedGenres.isEmpty {
                    CompatibilityChipRow(label: "Shared Genres", items: compatibility.sharedGenres, tint: tint)
                }
            }
        }
    }
}

private struct CompatibilityChipRow: View {
    let label: String
    let items: [String]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(AppTheme.bodyFont(size: 9))
                .foregroundStyle(AppTheme.textSecondary)
                .kerning(0.6)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items, id: \.self) { item in
                        Text(item)
                            .font(AppTheme.bodyFont(size: 11))
                            .foregroundStyle(AppTheme.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(tint.opacity(0.16)))
                    }
                }
            }
        }
    }
}

// MARK: - TopMusicShowcaseRow

/// "Top Genres" / "Top Artists" showcase — an auto-generated snapshot of
/// what someone actually listens to, built from the same
/// `get_user_taste_profile` signal already used for the Music Match score,
/// gated behind the profile's own `show_top_genres` opt-in (see
/// `MusicCompatibilityRow`'s doc comment for why artists/genres are kept as
/// separate chip rows rather than merged into one list).
struct TopMusicShowcaseRow: View {
    let topGenres: [String]
    let topArtists: [String]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !topArtists.isEmpty {
                CompatibilityChipRow(label: "Top Artists", items: topArtists, tint: tint)
            }
            if !topGenres.isEmpty {
                CompatibilityChipRow(label: "Top Genres", items: topGenres, tint: tint)
            }
        }
    }
}

// MARK: - ProfileCommentRow

/// One guestbook message row — author avatar/name, body text, relative
/// timestamp, and (when permitted) a delete button. Deletion is allowed for
/// whoever wrote the comment OR the profile owner moderating their own
/// guestbook, mirroring the bridge's `delete_profile_comment` rule exactly.
struct ProfileCommentRow: View {
    let comment: ProfileComment
    let tint: Color
    let canDelete: Bool
    let onDelete: () -> Void

    private var relativeTime: String {
        guard let date = comment.date else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SocialAvatarView(userId: comment.authorUserId, size: 32, fallbackFill: .clear)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(comment.authorDisplayName ?? comment.authorUsername)
                        .font(AppTheme.bodyFont(size: 13).weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    if !relativeTime.isEmpty {
                        Text(relativeTime)
                            .font(AppTheme.bodyFont(size: 11))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                Text(comment.body)
                    .font(AppTheme.bodyFont(size: 13))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            Spacer(minLength: 0)
            if canDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
    }
}

// MARK: - Feature: profile-customization-3 components
//
// Five more building blocks, mirroring the family above: milestone badges,
// a listening-streak stat, profile visitor stats, a featured/spotlight
// playlist, and a friends-only "recently played together" track list.

// MARK: - ProfileBadgeRow

/// A horizontally-scrolling row of milestone achievement chips (e.g.
/// "1 Year+", "500 Plays") — backed by `ProfileBadge`, always populated on
/// both the owner's editor and any visitor's read-only view (no privacy
/// toggle; these are public flair, like a Discord badge).
struct ProfileBadgeRow: View {
    let badges: [ProfileBadge]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(badges) { badge in
                    HStack(spacing: 5) {
                        Image(systemName: badge.icon)
                            .font(.caption2.weight(.bold))
                        Text(badge.label)
                            .font(AppTheme.bodyFont(size: 11).weight(.medium))
                    }
                    .foregroundStyle(Self.tierColor(badge.tier))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Self.tierColor(badge.tier).opacity(0.16)))
                }
            }
        }
    }

    static func tierColor(_ tier: String) -> Color {
        switch tier {
        case "gold":   return Color(red: 0.96, green: 0.78, blue: 0.15)
        case "silver": return Color(white: 0.72)
        default:       return Color(red: 0.80, green: 0.52, blue: 0.25) // bronze
        }
    }
}

// MARK: - ListeningStreakRow

/// "🔥 N day streak" plus a smaller "best streak" figure alongside it —
/// backed by `ListeningStreak`, computed live from play history on the
/// bridge (see `_compute_listening_streak`).
struct ListeningStreakRow: View {
    let streak: ListeningStreak
    let tint: Color

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(.orange)
                    Text("\(streak.currentStreakDays)")
                        .font(.title2.bold())
                        .foregroundStyle(AppTheme.textPrimary)
                }
                Text(streak.currentStreakDays == 1 ? "day streak" : "day streak")
                    .font(AppTheme.bodyFont(size: 11))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .frame(height: 32)
                .background(AppTheme.textSecondary.opacity(0.2))
                .padding(.horizontal, 14)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(streak.longestStreakDays)")
                    .font(.title3.bold())
                    .foregroundStyle(tint)
                Text("best streak")
                    .font(AppTheme.bodyFont(size: 11))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - ProfileVisitorStatsRow

/// "N profile views" plus a stack of small friend-visitor avatars —
/// backed by `visitorCount`/`recentVisitors` on MySocialProfile /
/// PublicSocialProfile. `recentVisitors` is only ever non-empty when the
/// viewer is a friend of the profile owner (see the bridge's
/// `_profile_visitor_stats`), so the avatar stack simply doesn't render
/// for a non-friend visitor even though the count above it still does.
struct ProfileVisitorStatsRow: View {
    let visitorCount: Int
    let recentVisitors: [ProfileVisitor]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "eye.fill")
                    .foregroundStyle(tint)
                Text(visitorCount == 1 ? "1 profile view" : "\(visitorCount) profile views")
                    .font(AppTheme.bodyFont(size: 13))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            if !recentVisitors.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Recent Visitors")
                        .font(AppTheme.bodyFont(size: 9))
                        .foregroundStyle(AppTheme.textSecondary)
                        .kerning(0.6)
                    HStack(spacing: -8) {
                        ForEach(recentVisitors.prefix(6)) { visitor in
                            SocialAvatarView(userId: visitor.userId, size: 28, fallbackFill: .clear)
                                .overlay(Circle().stroke(AppTheme.background, lineWidth: 2))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - FeaturedPlaylistRow

/// A spotlighted playlist card — cover-less (this app has no per-playlist
/// artwork concept server-side), so a tinted icon tile stands in, with the
/// track count and up to 3 track-title preview lines underneath, backed by
/// `FeaturedPlaylist`.
struct FeaturedPlaylistRow: View {
    let playlist: FeaturedPlaylist
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint.opacity(0.2))
                    Image(systemName: "music.note.list")
                        .foregroundStyle(tint)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .font(AppTheme.bodyFont(size: 14).weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    Text(playlist.trackCount == 1 ? "1 track" : "\(playlist.trackCount) tracks")
                        .font(AppTheme.bodyFont(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            if !playlist.previewTracks.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(playlist.previewTracks.enumerated()), id: \.offset) { _, track in
                        let artistSuffix = (track.artist?.isEmpty == false) ? " — \(track.artist!)" : ""
                        Text("• \(track.title)\(artistSuffix)")
                            .font(AppTheme.bodyFont(size: 11))
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

// MARK: - SharedRecentTracksRow

/// Extra feature #5's "Recently Played Together" list — backed by
/// `SharedRecentTrack`, only ever fetched between confirmed friends (see
/// GET /api/social/profile/{user_id}/recently-played-together).
struct SharedRecentTracksRow: View {
    let tracks: [SharedRecentTrack]
    let tint: Color

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                HStack(spacing: 10) {
                    Image(systemName: "music.note")
                        .font(.caption)
                        .foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(AppTheme.bodyFont(size: 13))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)
                        if let artist = track.artist, !artist.isEmpty {
                            Text(artist)
                                .font(AppTheme.bodyFont(size: 11))
                                .foregroundStyle(AppTheme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if index < tracks.count - 1 {
                    Divider().background(AppTheme.textSecondary.opacity(0.15))
                }
            }
        }
    }
}

// MARK: - PinnedTrackRow

/// One pinned-track row inside a Pinned Tracks `ProfileInfoCard` — shared
/// look between the owner's editable slot list and a public profile's
/// read-only list (the owner's version wraps this in a `Button`/adds a
/// chevron at the call site rather than duplicating the row layout).
struct PinnedTrackRow: View {
    let title: String
    let artist: String?
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pin.fill")
                .font(.caption)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppTheme.bodyFont(size: 14))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                if let artist, !artist.isEmpty {
                    Text(artist)
                        .font(AppTheme.bodyFont(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
    }
}
