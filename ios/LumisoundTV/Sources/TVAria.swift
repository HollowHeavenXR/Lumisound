import SwiftUI

// MARK: - Aria Lumi on tvOS
//
// Aria is the bridge's intelligence layer (ios-bridge/intelligence.py). On iOS
// she does a lot of things, and most of them do not belong on a television:
// metadata disambiguation, duplicate resolution and cloud cleanup all act on
// FILES, and tvOS owns no files — it streams someone else's library. Porting
// those would mean putting destructive, hard-to-review decisions behind a remote
// control, which is the wrong device for them.
//
// What is ported is what a 10-foot screen is actually good at:
//
//   * **Daily Pick** (`GET /user/aria/daily-pick`) — one track Aria chose out of
//     the library for today, with her reason for choosing it. Passive, needs no
//     input, and gives Home something that changes day to day.
//   * **DJ transitions** (`POST /user/ai-dj/transition`) — a one-line spoken
//     handover into the track that's starting. This is the piece that most
//     benefits from a television: it is the one Aria feature that is better
//     heard across a room than read on a phone.
//
// She is not switchable. The settings screen has no toggle for her by design —
// see `TVSettingsView`. That is also why nothing here has an "enabled" check: a
// disabled path that cannot be reached is a path that rots.
//
// NOTHING in this file touches the iOS app. Aria's iOS surface (AccountService+
// Intelligence, AriaActivityLog, AriaCloudCleanupService) is untouched; this
// calls the same HTTP endpoints independently, so tvOS cannot regress her
// behaviour on the phone.

// MARK: Models

struct TVAriaDailyPick: Decodable, Equatable {
    struct Pick: Decodable, Equatable {
        let title: String?
        let artist: String?
    }
    let pick: Pick?
    let reason: String?

    var isPresent: Bool { pick?.title?.isEmpty == false }
}

// MARK: Service

@MainActor
final class TVAria: ObservableObject {
    static let shared = TVAria()

    /// Today's pick. Cached server-side per user per day, so refetching on every
    /// launch costs a cache read rather than a model call.
    @Published private(set) var dailyPick: TVAriaDailyPick?
    /// The handover line for the track that just started, shown briefly in the
    /// now-playing card and the full player.
    @Published private(set) var currentBlurb: String?
    @Published private(set) var isThinking = false

    private var blurbTask: Task<Void, Never>?
    private var lastBlurbTrackID: String?
    /// When Aria last actually spoke, so she does not speak over every track.
    private var lastBlurbAt: Date?
    private var tracksSinceBlurb = 0

    /// Aria introduces roughly one track in four, and never twice inside two
    /// minutes.
    ///
    /// She was asked for a line on EVERY track change. Two problems with that.
    /// The obvious one is quota: measured over twelve hours, 11 requests
    /// completed, 11 failed on upstream 503s and 8 were rate-limited outright —
    /// a 63% failure rate, with the rate-limit cooldown then returning nothing
    /// instantly for minutes afterwards. It also crowded out the uses of Aria
    /// that are worth more, since the daily pick and lyrics transcription draw
    /// on the same quota.
    ///
    /// The less obvious one is that it was the wrong behaviour anyway. A radio
    /// DJ does not announce every song; talking over all of them is what makes
    /// the feature tiresome rather than characterful. Rationing her makes each
    /// line mean something.
    private static let tracksBetweenBlurbs = 4
    private static let minimumInterval: TimeInterval = 120

    private var baseURL: String { TVBridgeClient.shared.baseURL }

    // MARK: Daily pick

    func loadDailyPick(token: String) async {
        guard let url = URL(string: baseURL + "/user/aria/daily-pick") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let started = Date()
        do {
            let (data, response) = try await Core.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status) else {
                TVRemoteLogger.logError(category: "aria", event: "daily_pick_failed",
                                        message: "HTTP \(status)", detail: ["status": status],
                                        authToken: token)
                return
            }
            let decoded = try JSONDecoder().decode(TVAriaDailyPick.self, from: data)
            dailyPick = decoded
            TVRemoteLogger.log(
                category: "aria", event: "daily_pick_loaded",
                detail: ["hasPick": decoded.isPresent,
                         "hasReason": decoded.reason?.isEmpty == false,
                         "elapsedMs": Int(Date().timeIntervalSince(started) * 1000)],
                authToken: token
            )
        } catch {
            // A cancelled fetch is the screen going away mid-request, not a
            // failure — logging it as one buries genuine errors, exactly as it
            // did on the generic network path before 1.17.1.
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            TVRemoteLogger.logError(category: "aria", event: "daily_pick_failed",
                                    message: error.localizedDescription, authToken: token)
        }
    }

    // MARK: DJ transitions

    /// Asks Aria for a handover line into `next`.
    ///
    /// Deliberately fire-and-forget and never blocking: the track starts playing
    /// regardless of whether she answers, or how slowly. An intelligence feature
    /// that can delay audio is worse than no intelligence feature, so the blurb
    /// simply appears when it arrives and is skipped when it doesn't.
    func requestTransition(from previous: TVPlayable?, to next: TVPlayable, token: String) {
        guard lastBlurbTrackID != next.id else { return }
        lastBlurbTrackID = next.id

        // Counted for every track, but only acted on occasionally — see
        // `tracksBetweenBlurbs`.
        tracksSinceBlurb += 1
        let longEnough = lastBlurbAt.map { Date().timeIntervalSince($0) >= Self.minimumInterval } ?? true
        guard tracksSinceBlurb >= Self.tracksBetweenBlurbs, longEnough else {
            currentBlurb = nil
            return
        }
        tracksSinceBlurb = 0
        lastBlurbAt = Date()
        blurbTask?.cancel()
        currentBlurb = nil

        blurbTask = Task { [weak self] in
            guard let self else { return }
            self.isThinking = true
            defer { self.isThinking = false }

            guard let url = URL(string: self.baseURL + "/user/ai-dj/transition") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = [
                "next_title": next.title,
                "next_artist": next.artist,
            ]
            if let previous {
                body["previous_title"] = previous.title
                body["previous_artist"] = previous.artist
            }
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)

            struct Response: Decodable { let blurb: String? }
            let started = Date()
            do {
                let (data, response) = try await Core.data(for: req)
                guard !Task.isCancelled, self.lastBlurbTrackID == next.id else { return }

                // The status is checked BEFORE decoding. It was ignored, so an
                // overloaded or rate-limited reply — which carries {"detail": …}
                // rather than {"blurb": …} — was fed to the success decoder and
                // surfaced as "the data couldn't be read because it isn't in the
                // correct format". That reads like a parsing bug in our own
                // code, when it is simply Aria being busy, and it buried the
                // real reason under a misleading message.
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard (200..<300).contains(status) else {
                    TVRemoteLogger.log(
                        category: "aria", event: "dj_blurb_unavailable",
                        detail: ["status": status, "title": next.title],
                        authToken: token
                    )
                    return
                }

                let decoded = try JSONDecoder().decode(Response.self, from: data)
                let text = decoded.blurb?.trimmingCharacters(in: .whitespacesAndNewlines)
                self.currentBlurb = (text?.isEmpty == false) ? text : nil
                TVRemoteLogger.log(
                    category: "aria", event: text?.isEmpty == false ? "dj_blurb_received" : "dj_blurb_empty",
                    detail: ["title": next.title,
                             "hadPrevious": previous != nil,
                             "elapsedMs": Int(Date().timeIntervalSince(started) * 1000)],
                    authToken: token
                )
            } catch {
                guard (error as NSError).code != NSURLErrorCancelled else { return }
                // Silent by design — see the doc comment. Logged, not surfaced.
                TVRemoteLogger.logError(category: "aria", event: "dj_blurb_failed",
                                        message: error.localizedDescription, authToken: token)
            }
        }
    }

    func clearBlurb() {
        currentBlurb = nil
    }
}

// MARK: - Aria's presence in the UI

/// The line Aria says over a track change, styled as HER voice rather than as
/// app chrome — an accent-lit mark and italic text, so it reads as something
/// said rather than as a label the app printed.
struct TVAriaBlurbView: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            TVAriaMark(isAnimating: true)
            Text(text)
                .font(.system(size: 21, weight: .medium, design: .rounded))
                .italic()
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(TVPalette.violet.opacity(0.2))
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

/// Aria's mark: a small ring with a pulsing core. Deliberately not a face or a
/// cartoon — she is a voice in the app, and a literal avatar would make her a
/// character competing with the artwork for attention.
struct TVAriaMark: View {
    var isAnimating: Bool = false
    var diameter: CGFloat = 26

    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(TVPalette.brand, lineWidth: max(2, diameter * 0.07))
            Circle()
                .fill(TVPalette.brand)
                .frame(width: diameter * 0.34, height: diameter * 0.34)
                .scaleEffect(pulse ? 1.35 : 0.85)
                .opacity(pulse ? 1 : 0.6)
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: TVPalette.violet.opacity(0.7), radius: max(8, diameter * 0.25))
        .onAppear {
            guard isAnimating else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

/// Aria's Daily Pick, as a Home card — wide, in her violet, with her reason in
/// her own (rounded, italic) voice.
struct TVAriaDailyPickCard: View {
    let pick: TVAriaDailyPick
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            TVAriaMark(isAnimating: true, diameter: 64)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 10) {
                Text("ARIA'S DAILY PICK")
                    .font(TVType.eyebrow)
                    .tracking(2.4)
                    .foregroundStyle(TVPalette.neonAlt)
                Text(pick.pick?.title ?? "")
                    .font(.system(size: 36, weight: .heavy, design: .rounded))
                    .lineLimit(2)
                Text(pick.pick?.artist ?? "")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(TVPalette.textSecondary)
                    .lineLimit(1)
                if let reason = pick.reason, !reason.isEmpty {
                    Text("“\(reason)”")
                        .font(.system(size: 21, design: .rounded))
                        .italic()
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 900, alignment: .leading)
        .padding(32)
        .background {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(
                    LinearGradient(colors: [TVPalette.violet.opacity(0.45), TVPalette.blue.opacity(0.18)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        }
        .tvNeonCard(cornerRadius: 30, isFocused: isFocused, tint: TVPalette.neonAlt)
    }
}
