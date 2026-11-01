import SwiftUI

// MARK: - TVAvatarView
//
// A user's actual picture, replacing the generic `person.crop.circle.fill`
// glyph the account screen showed for everyone.
//
// The image is served from `/user/avatar/{id}` as raw bytes for accounts that
// uploaded one, or from an external `avatar_url` otherwise — `TVUser.avatarURL`
// picks between them. `TVAuthImage` does the loading so this inherits its
// retry-once behaviour and its cross-dissolve, and falls back to the glyph when
// an account genuinely has no picture (that endpoint 404s, which is a normal
// state here, not an error).
struct TVAvatarView: View {
    let user: TVUser?
    let baseURL: String
    var diameter: CGFloat = 130
    /// Rings the avatar in the app's neon — used where the avatar is the
    /// subject (the profile card) rather than a row's leading detail.
    var showsRing: Bool = true

    var body: some View {
        TVAuthImage(url: user?.avatarURL(baseURL: baseURL), token: nil) {
            ZStack {
                TVGeneratedArt(seed: user?.name ?? "", systemImage: "person.fill")
                Text(String((user?.name ?? "?").prefix(1)).uppercased())
                    .font(.system(size: diameter * 0.42, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay {
            if showsRing {
                Circle()
                    .strokeBorder(TVPalette.brand, lineWidth: 4)
            } else {
                Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
            }
        }
        .shadow(color: showsRing ? TVPalette.violet.opacity(0.5) : .clear, radius: 24, y: 8)
    }
}

// MARK: - Listening activity
//
// `GET /social/activity` — recent plays from accounts that opted in to sharing
// their listening activity. The bridge has carried this for a while and only
// the phone ever read it.
//
// Of everything on the social surface, this is the one worth having on a TV:
// it is a passive, glanceable feed of real activity that needs no input to be
// useful, which is exactly what a 10-foot screen is good at. The interactive
// parts of the social system — following, sharing a playlist, editing a profile
// — are all text entry and account management, which are genuinely better on
// the phone, so they are deliberately not ported here.

struct TVSocialActivity: Identifiable, Decodable {
    let username: String?
    let display_name: String?
    let avatar_url: String?
    let title: String?
    let artist: String?
    let played_at: String?

    /// Composed rather than server-supplied: the endpoint returns no row id,
    /// and a user can legitimately appear several times in the feed, so the
    /// identity has to include what they played and when.
    var id: String { "\(username ?? "?")|\(title ?? "?")|\(played_at ?? "?")" }

    var name: String { display_name ?? username ?? "Someone" }

    /// "just now" / "12m" / "3h" / "5d" — a feed of timestamps is unreadable at
    /// a distance; elapsed time is what the entry actually means.
    var relativeTime: String {
        guard let played_at, let date = tvParseISO8601(played_at) else { return "" }
        let seconds = Date().timeIntervalSince(date)
        if seconds < 90 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

    /// Avatars here come from the feed's own `avatar_url` — these are other
    /// people, so there is no account id to build an upload URL from.
    var avatarLink: URL? {
        guard let avatar_url, !avatar_url.isEmpty else { return nil }
        return URL(string: avatar_url)
    }
}

extension TVBridgeClient {
    /// Fetches the shared listening feed. Failures are logged and leave the
    /// existing feed in place: this is ambient content, and a blank panel is a
    /// worse outcome than a slightly stale one.
    func fetchSocialActivity(token: String, limit: Int = 20) async {
        guard var comps = URLComponents(string: baseURL + "/social/activity") else { return }
        comps.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        guard let url = comps.url else { return }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        struct Response: Decodable { let activity: [TVSocialActivity] }
        let started = Date()
        do {
            let (data, response) = try await Core.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status) else {
                TVRemoteLogger.logError(
                    category: "social", event: "social_activity_failed",
                    message: "HTTP \(status)", detail: ["status": status], authToken: token
                )
                return
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            socialActivity = decoded.activity
            TVRemoteLogger.log(
                category: "social", event: "social_activity_loaded",
                detail: ["count": decoded.activity.count,
                         "distinctUsers": Set(decoded.activity.map { $0.username ?? "" }).count,
                         "elapsedMs": Int(Date().timeIntervalSince(started) * 1000)],
                authToken: token
            )
        } catch {
            TVRemoteLogger.logError(
                category: "social", event: "social_activity_failed",
                message: error.localizedDescription, authToken: token
            )
        }
    }
}

// MARK: - Activity feed view

struct TVSocialActivityFeed: View {
    let activity: [TVSocialActivity]

    var body: some View {
        VStack(alignment: .leading, spacing: TVMetrics.row) {
            if activity.isEmpty {
                HStack(spacing: 20) {
                    Image(systemName: "person.2.wave.2.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(TVPalette.brandVertical)
                    Text("No shared listening activity yet. Activity appears here when people you listen alongside opt in.")
                        .font(TVType.rowDetail)
                        .foregroundStyle(TVPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .tvNeonCard(cornerRadius: 22)
            } else {
                // Not focusable: a feed of what other people played is a
                // readout, and nothing here has an action behind it — their
                // tracks are not necessarily in this user's library. Making the
                // rows focusable would add a column of dead stops to the
                // account screen's focus path.
                ForEach(activity.prefix(6)) { entry in
                    HStack(spacing: 18) {
                        TVAuthImage(url: entry.avatarLink, token: nil) {
                            ZStack {
                                TVGeneratedArt(seed: entry.name, systemImage: "person.fill")
                                Text(String(entry.name.prefix(1)).uppercased())
                                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                            }
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())
                        .overlay { Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1) }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title ?? "Unknown track")
                                .font(.system(size: 23, weight: .semibold))
                                .lineLimit(1)
                            Text("\(entry.name) · \(entry.artist ?? "Unknown Artist")")
                                .font(.system(size: 19))
                                .foregroundStyle(TVPalette.textTertiary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 12)

                        Text(entry.relativeTime)
                            .font(TVType.meta)
                            .foregroundStyle(TVPalette.textTertiary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .tvNeonCard(cornerRadius: 22)
                }
            }
        }
    }
}
