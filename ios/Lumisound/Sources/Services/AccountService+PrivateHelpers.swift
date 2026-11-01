import Foundation
import SwiftUI
import UIKit

extension AccountService {

    // MARK: - Private helpers

    struct EmptyBody: Encodable {}

    struct AuthResponse: Decodable {
        let user: AppUser
        let token: String
    }

    /// /auth/login's alternate response shape for a 2FA-enabled account —
    /// see `login()`'s doc comment.
    struct TOTPPendingResponse: Decodable {
        let requires_2fa: Bool
        let pending_token: String
    }

    func saveUserLocally(_ user: AppUser) {
        if let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: Self.userKey)
        }
    }

    func handleUnauthorized() {
        appWarn("JWT expired or invalid — clearing session", category: "account")
        // Snapshot the token before clearing it below — RemoteLogger's send
        // is fire-and-forget and runs on a later run-loop turn, so reading
        // the *live* token from inside it would very likely already see nil
        // and lose this event's user attribution entirely.
        let priorToken = token
        RemoteLogger.logError(category: "auth", event: "session_expired",
                               message: "JWT expired or invalid — clearing local session",
                               authToken: priorToken)
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.userKey)
        token = nil
        currentUser = nil
        isLoggedIn = false
        errorMessage = "Your session expired. Please sign in again."
    }

    func clearSession() {
        // Covers logout, account deletion, and self/other session revocation
        // (see AccountService+PublicAPI.swift / +Sessions.swift /
        // +PasswordAndDeletion.swift, which all call this) — logged once
        // here rather than at each call site so every path that ends a
        // local session is covered without duplicating the event. Snapshot
        // the token first — see handleUnauthorized above for why.
        let priorToken = token
        RemoteLogger.log(category: "auth", event: "local_session_cleared", authToken: priorToken)
        token = nil
        currentUser = nil
        isLoggedIn = false
        hasDateOfBirth = false
        // A stream ticket is bound to the account that asked for it, so it must
        // not survive into the next session's stream URLs. Cleared here rather
        // than in logout() because every path that ends a session comes through
        // this function — account deletion and session revocation included.
        StreamingService.clearStreamTicket()
        syncInventoryReset()
        avatarImage = nil
        stopAutoPushTimer()
        UserDefaults.standard.removeObject(forKey: Self.userKey)
    }

    func makeRequest<T: Encodable>(_ path: String, method: String = "GET", body: T,
                                   timeout: TimeInterval? = nil) async throws -> Data {
        try await _makeRequest(path, method: method,
                               bodyData: try JSONEncoder().encode(body), timeout: timeout)
    }

    func makeRequest(_ path: String, method: String = "GET",
                     timeout: TimeInterval? = nil) async throws -> Data {
        try await _makeRequest(path, method: method, bodyData: nil, timeout: timeout)
    }

    /// `timeout` overrides the 20s default for the handful of calls whose work is
    /// inherently proportional to library size. 20s is right for the ordinary
    /// small request and demonstrably too short for a bulk one — the library
    /// inventory upload sends every owned source id at once (3,378 for the largest
    /// account here) and the server replaces the whole set, which is what produced
    /// a long tail of "request timed out" on that one endpoint.
    /// `maxAttempts` > 1 retries with backoff — only for idempotent writes
    /// (the default retries GETs only; a retried write could double-apply).
    func _makeRequest(_ path: String, method: String, bodyData: Data?,
                      timeout: TimeInterval? = nil, maxAttempts: UInt32? = nil) async throws -> Data {
        // Transport, retries (idempotent GETs only — a retried write could
        // double-apply), FastAPI error bodies and 401 detection all live in
        // the Rust core's ApiClient.
        Core.prepare(baseURL: bridgeURL, token: token)
        do {
            let data = if let maxAttempts {
                try await Core.api.requestWithRetry(path: path, method: method, body: bodyData, timeoutSecs: timeout,
                                                    maxAttempts: maxAttempts, baseDelay: 0.8)
            } else {
                try await Core.api.request(path: path, method: method, body: bodyData, timeoutSecs: timeout)
            }
            // Swift task cancellation doesn't reach the Rust future; honour it
            // here so superseded debounced calls still read as cancelled.
            if Task.isCancelled { throw URLError(.cancelled) }
            return data
        } catch let e as CoreError {
            if Task.isCancelled { throw URLError(.cancelled) }
            switch e {
            case .Unauthorized:
                // Only auto-logout on 401 when already logged in: a 401 on
                // /auth/login means a wrong password, not an expired token.
                if isLoggedIn && path != "/auth/login" { handleUnauthorized() }
                throw AccountError(statusCode: 401, message: "Session expired. Please sign in again.")
            case let .Http(status, message):
                throw AccountError(statusCode: Int(status), message: message)
            default:
                if let u = Core.urlError(e) { throw u }
                throw AccountError(statusCode: 0, message: e.localizedDescription)
            }
        }
    }
}
