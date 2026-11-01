import Foundation

// MARK: - Stream tickets
//
// A short-lived credential the app puts in the QUERY STRING of a stream URL,
// because AVPlayer cannot be relied on to carry a header there.
//
// The player is handed the bridge's proxy URL and fetches it itself. Auth rides
// on `AVURLAsset`'s "AVURLAssetHTTPHeaderFieldsKey" option, which applies to the
// opening request and is not reliably reapplied to the byte-range requests that
// follow it. Telemetry settled this beyond argument: of every recorded proxy
// rejection carrying range information, 309 of 309 were RANGED requests and not
// one was unranged. So a track starts, plays for a moment, and dies the instant
// the player asks for its second range — reported as tracks that simply refuse
// to play, with a 404/-1100 in the log that pointed at the wrong thing entirely.
//
// A URL survives where a header does not, so the credential moves into the URL.
// Deliberately NOT the account token: query strings end up in server access logs
// and a session token has no business there. A ticket is opaque, carries nothing
// about the account on its face, is bound to the user server-side, and expires.
extension StreamingService {

    private static var cachedTicket: String?
    private static var cachedTicketExpiry: Date = .distantPast

    /// A usable ticket, reusing the cached one until it is close to expiring.
    ///
    /// Refreshed well before the server's own TTL so a long track can never have
    /// its ticket expire underneath it mid-playback.
    func streamTicket() async -> String? {
        if let ticket = Self.cachedTicket, Date() < Self.cachedTicketExpiry {
            return ticket
        }
        struct Response: Decodable {
            let ticket: String
            let expires_in: Double?
        }
        guard AccountService.shared?.token != nil else {
            // Not signed in: nothing to bind a ticket to. The service-key header
            // path still covers the opening request, and this is no worse than
            // the behaviour before tickets existed.
            return nil
        }
        do {
            guard var request = makeRequest("/api/stream/ticket") else { return nil }
            if let token = AccountService.shared?.token {
                request.setValue(token, forHTTPHeaderField: "X-Account-Token")
            }
            request.timeoutInterval = 15
            let (data, response) = try await Core.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                appWarn("streamTicket: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)", category: "network")
                return nil
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let ttl = decoded.expires_in ?? 3600
            // Renew at half life rather than at the edge.
            Self.cachedTicket = decoded.ticket
            Self.cachedTicketExpiry = Date().addingTimeInterval(ttl / 2)
            appLog("streamTicket: issued, reusing for \(Int(ttl / 2))s", category: "network")
            return decoded.ticket
        } catch {
            appWarn("streamTicket: \(error.localizedDescription)", category: "network")
            return nil
        }
    }

    /// Drops the cached ticket — called on sign-out so a ticket belonging to the
    /// previous account is never appended to the next one's stream URLs.
    static func clearStreamTicket() {
        cachedTicket = nil
        cachedTicketExpiry = .distantPast
    }
}
