import Foundation

/// One AI-assisted metadata pick, as returned by `resolveMetadata`. Carries
/// `memoryID` so a later manual correction (see
/// `LibraryManager.applyMetadataCorrection`) can be reported back to Aria
/// Lumi via `reportMetadataCorrection`, closing the learning loop.
struct MetadataResolution {
    let bestIndex: Int
    let memoryID: Int?
}

extension AccountService {

    // MARK: - Aria Lumi (built-in; see ios-bridge/intelligence.py)

    /// Asks Aria Lumi (the bridge's AI-assisted metadata resolver) to pick
    /// the best candidate for a local file's metadata. Runs for every
    /// signed-in user unconditionally — no per-user opt-in anymore (see
    /// `AccountView`'s "Aria Lumi" section, no longer a toggle). Returns
    /// `nil` whenever the user is logged out, the network call fails, or she
    /// has no confident pick — in every case the caller falls back to its
    /// existing exact-match-or-first-result heuristic unchanged.
    func resolveMetadata(filename: String, candidates: [MetadataCandidate]) async -> MetadataResolution? {
        guard isLoggedIn, !candidates.isEmpty else {
            return nil
        }
        struct Body: Encodable {
            let filename: String
            let candidates: [MetadataCandidate]
        }
        struct Response: Decodable {
            let best_index: Int?
            let confidence: String
            let memory_id: Int?
        }
        do {
            let data = try await makeRequest(
                "/user/intelligence/metadata-resolve",
                method: "POST",
                body: Body(filename: filename, candidates: candidates)
            )
            let result = try JSONDecoder().decode(Response.self, from: data)
            guard let index = result.best_index, index >= 0, index < candidates.count else {
                return nil
            }
            return MetadataResolution(bestIndex: index, memoryID: result.memory_id)
        } catch {
            return nil
        }
    }

    /// Asks Aria Lumi which copy in a Duplicate Finder group to KEEP, given
    /// more signal than the on-device heuristic (`DuplicateFinderService
    /// .allDuplicatesToRemove`) uses on its own: format/bitrate/sample rate,
    /// whether each copy's embedded metadata tag survived, and whether the
    /// user has favorited that specific copy — a favorited copy should
    /// essentially never be the one silently deleted, which the duration-
    /// only heuristic has no way to know about. `nil` whenever logged out,
    /// the call fails, or she has no confident pick — the caller always
    /// falls back to the existing heuristic unchanged in that case; this is
    /// a refinement, never the sole authority for a destructive delete.
    func resolveDuplicateKeeper(
        title: String, artist: String, reason: String, candidates: [DuplicateResolveCandidate]
    ) async -> DuplicateResolution? {
        guard isLoggedIn, candidates.count > 1 else { return nil }
        struct Body: Encodable {
            let title: String
            let artist: String
            let reason: String
            let candidates: [DuplicateResolveCandidate]
        }
        struct Response: Decodable {
            let keep_index: Int?
            let confidence: String
            let memory_id: Int?
        }
        do {
            let data = try await makeRequest(
                "/user/intelligence/duplicate-resolve",
                method: "POST",
                body: Body(title: title, artist: artist, reason: reason, candidates: candidates)
            )
            let result = try JSONDecoder().decode(Response.self, from: data)
            guard let index = result.keep_index, index >= 0, index < candidates.count else {
                return nil
            }
            return DuplicateResolution(keepIndex: index, memoryID: result.memory_id, confidence: result.confidence)
        } catch {
            return nil
        }
    }

    /// Reports that a user manually corrected a song's title/artist after
    /// Aria Lumi previously resolved it for this filename (see
    /// `IntelligenceSuggestionCache`). Fire-and-forget: failures are silent
    /// since this is a learning signal, not a user-facing action.
    func reportMetadataCorrection(memoryID: Int, title: String, artist: String) async {
        guard isLoggedIn else { return }
        struct Body: Encodable {
            let memory_id: Int
            let correction: [String: String]
        }
        _ = try? await makeRequest(
            "/user/intelligence/feedback",
            method: "POST",
            body: Body(memory_id: memoryID, correction: ["title": title, "artist": artist])
        )
    }

    /// Reports that a user manually kept a different copy than Aria Lumi
    /// suggested in a Duplicate Finder group. Fire-and-forget, same as
    /// `reportMetadataCorrection` — a learning signal, not a user-facing
    /// action, so failures are silent.
    func reportDuplicateCorrection(memoryID: Int, keptIndex: Int) async {
        guard isLoggedIn else { return }
        struct Body: Encodable {
            let memory_id: Int
            let correction: [String: Int]
        }
        _ = try? await makeRequest(
            "/user/intelligence/feedback",
            method: "POST",
            body: Body(memory_id: memoryID, correction: ["keep_index": keptIndex])
        )
    }

    /// Fetches today's Aria's Daily Pick — cached server-side per user per
    /// UTC calendar day (see `/user/aria/daily-pick` in main.py), so calling
    /// this more than once in the same day is free and never costs an
    /// extra Gemini call. Populates `ariaDailyPick`; leaves it untouched on
    /// failure so a transient network error doesn't blank out an
    /// already-loaded pick.
    func fetchAriaDailyPick() async {
        guard isLoggedIn else { return }
        do {
            let data = try await makeRequest("/user/aria/daily-pick")
            ariaDailyPick = try JSONDecoder().decode(AriaDailyPick.self, from: data)
        } catch {
            appWarn("fetchAriaDailyPick: \(error.localizedDescription)", category: "network")
        }
    }

    /// Logs a real action Aria Lumi just took on an existing track (see
    /// `AriaActivityLog`) to the bridge's deep action log (`ios_aria_actions`),
    /// after the local action (trashing a duplicate, rewriting tags) has
    /// already happened — this call is a log write, not a request for
    /// permission. Returns the server-assigned action id (used later to
    /// report a revert), or `nil` on any failure — the local
    /// `AriaActivityLog` entry and the revert UI it powers work entirely
    /// off-device regardless, so a failure here only means this particular
    /// action won't show up in the server-side audit trail.
    func reportAriaAction(
        type: String, title: String, artist: String?, detail: String?,
        before: [String: String]? = nil, after: [String: String]? = nil,
        confidence: String?, memoryID: Int?
    ) async -> Int? {
        guard isLoggedIn else { return nil }
        struct Body: Encodable {
            let action_type: String
            let title: String
            let artist: String?
            let detail: String?
            let before: [String: String]?
            let after: [String: String]?
            let confidence: String?
            let memory_id: Int?
        }
        struct Response: Decodable { let id: Int }
        do {
            let data = try await makeRequest(
                "/user/intelligence/actions",
                method: "POST",
                body: Body(
                    action_type: type, title: title, artist: artist, detail: detail,
                    before: before, after: after, confidence: confidence, memory_id: memoryID
                )
            )
            return try JSONDecoder().decode(Response.self, from: data).id
        } catch {
            return nil
        }
    }

    /// Reports that an Aria action (by its server-assigned id from
    /// `reportAriaAction`) was reverted locally — fire-and-forget, same
    /// silent-failure contract as `reportMetadataCorrection`: the local
    /// revert already happened regardless of whether this write succeeds.
    func reportAriaActionReverted(actionID: Int) async {
        guard isLoggedIn else { return }
        _ = try? await makeRequest("/user/intelligence/actions/\(actionID)/revert", method: "POST")
    }

    /// Aria Lumi's cloud-library counterpart to the on-device corrupt-file
    /// auto-delete: asks the bridge to remove any `ios_user_music_metadata`
    /// row that doesn't point at a real, playable file (a failed/partial
    /// upload — zero/unknown size, non-positive duration) — see
    /// `/user/intelligence/cloud-cleanup` in main.py for the exact bar and
    /// why this one skips the local trash-first contract (there's no real
    /// audio behind these rows to protect). Returns the titles removed, for
    /// the caller to log/toast; empty on any failure or when logged out.
    func ariaCloudCleanup() async -> [(filename: String, title: String)] {
        guard isLoggedIn else { return [] }
        struct RemovedEntry: Decodable { let filename: String; let title: String }
        struct Response: Decodable { let removed: [RemovedEntry] }
        do {
            let data = try await makeRequest("/user/intelligence/cloud-cleanup", method: "POST")
            return try JSONDecoder().decode(Response.self, from: data).removed.map { ($0.filename, $0.title) }
        } catch {
            return []
        }
    }

    /// Fetches (or triggers, on a first-ever request for this album) a
    /// short Aria Lumi liner-notes blurb for `artist`/`album` — cached
    /// server-side per album, not per user, so most calls are free (see
    /// `/music/liner-notes` in main.py). `nil` when logged out, the album
    /// isn't recognized/confident enough, or the request fails.
    func fetchLinerNotes(artist: String, album: String) async -> String? {
        guard isLoggedIn,
              let encodedArtist = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let encodedAlbum = album.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        do {
            let data = try await makeRequest("/music/liner-notes?artist=\(encodedArtist)&album=\(encodedAlbum)")
            struct Response: Decodable { let blurb: String? }
            return try JSONDecoder().decode(Response.self, from: data).blurb
        } catch {
            return nil
        }
    }
}
