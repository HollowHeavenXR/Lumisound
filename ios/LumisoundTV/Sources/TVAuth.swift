import Foundation

// MARK: - Auth models

struct TVUser: Codable, Hashable {
    let id: String?
    let username: String?
    let display_name: String?
    /// Externally-hosted avatar, when the account has one set that way. Accounts
    /// that uploaded an image instead have it stored as bytes on the server and
    /// served from `/user/avatar/{id}` — see `avatarURL(baseURL:)`.
    let avatar_url: String?

    var name: String { display_name ?? username ?? "You" }

    /// Where to load this user's picture from, preferring the uploaded image.
    ///
    /// All four fields are optional and decoded leniently: this type is built
    /// from several different endpoints' user objects, and an older bridge (or
    /// a response that only carries a name) must still decode rather than fail
    /// the whole login. `id` being nil simply means no uploaded-avatar URL can
    /// be formed, which the caller renders as the placeholder glyph.
    func avatarURL(baseURL: String) -> URL? {
        if let id, !id.isEmpty {
            return URL(string: "\(baseURL)/user/avatar/\(id)")
        }
        if let avatar_url, !avatar_url.isEmpty {
            return URL(string: avatar_url)
        }
        return nil
    }
}

private struct TVAuthResponse: Decodable {
    let token: String
    let user: TVUser?
}

// MARK: - TVAccount
//
// Minimal account service for tvOS: logs in against the bridge (/auth/login),
// persists the JWT, and exposes it for authenticated requests (per-user library).

@MainActor
final class TVAccount: ObservableObject {
    static let shared = TVAccount()

    @Published private(set) var token: String?
    @Published private(set) var user: TVUser?
    @Published var isLoggingIn = false
    @Published var errorText: String?

    var isLoggedIn: Bool { token != nil }

    private let baseURL = TVBridgeClient.shared.baseURL
    private let tokenKey = "tv.auth.token"
    private let userKey = "tv.auth.user"

    private init() {
        if let keychainToken = TVKeychainTokenStore.get(account: tokenKey) {
            token = keychainToken
        } else if let legacyToken = UserDefaults.standard.string(forKey: tokenKey) {
            // One-time migration from the old UserDefaults-backed token —
            // move it into the Keychain and scrub the plaintext copy so a
            // pre-existing login isn't lost by this change.
            token = legacyToken
            TVKeychainTokenStore.set(legacyToken, account: tokenKey)
            UserDefaults.standard.removeObject(forKey: tokenKey)
        }
        if let data = UserDefaults.standard.data(forKey: userKey) {
            user = try? JSONDecoder().decode(TVUser.self, from: data)
        }
    }

    func login(username: String, password: String) async {
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty, !password.isEmpty else {
            errorText = "Enter your username and password."
            return
        }
        isLoggingIn = true
        errorText = nil
        defer { isLoggingIn = false }

        guard let url = URL(string: baseURL + "/auth/login") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        let body = ["username": u, "password": password, "device_name": "Apple TV"]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await Core.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                errorText = "Login failed. Try again."
                tvWarn("Login failed: no HTTP response", category: "auth")
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                errorText = http.statusCode == 401
                    ? "Incorrect username or password."
                    : "Login failed (HTTP \(http.statusCode))."
                tvWarn("Login failed", category: "auth", extra: ["status": "\(http.statusCode)"])
                TVRemoteLogger.logError(category: "auth", event: "login_failed",
                                         message: "HTTP \(http.statusCode)")
                return
            }
            let decoded = try JSONDecoder().decode(TVAuthResponse.self, from: data)
            token = decoded.token
            user = decoded.user
            TVKeychainTokenStore.set(decoded.token, account: tokenKey)
            if let user = decoded.user, let enc = try? JSONEncoder().encode(user) {
                UserDefaults.standard.set(enc, forKey: userKey)
            }
            tvBreadcrumb("Logged in")
            tvLog("Login succeeded", category: "auth")
            TVRemoteLogger.log(category: "auth", event: "login_succeeded", authToken: decoded.token)
        } catch {
            errorText = error.localizedDescription
            tvWarn("Login failed: \(error.localizedDescription)", category: "auth")
            TVRemoteLogger.logError(category: "auth", event: "login_failed", message: error.localizedDescription)
        }
    }

    /// Checks the restored token against the bridge and signs out if it's no
    /// longer valid.
    ///
    /// On tvOS the Keychain SURVIVES deleting and reinstalling the app (unlike
    /// UserDefaults and the app container), so a fresh install silently comes
    /// back signed in with whatever token was last stored — possibly from a
    /// different account, a revoked session, or a token the server no longer
    /// honours. Nothing validated it: `init()` restored it and the app went
    /// straight to the signed-in UI, so a dead token left the app stuck
    /// "logged in" with every request failing and no obvious way to get to a
    /// login screen.
    ///
    /// It also restores the display name, which a reinstall DOES lose (that
    /// lives in UserDefaults), so the profile card stops showing a generic
    /// "Signed in" for an account it can't name.
    ///
    /// Only a definitive 401/403 signs out. A network error or a 5xx leaves
    /// the session alone — being logged out because the TV was offline at
    /// launch, or because the bridge was briefly restarting, would be a much
    /// worse failure than a stale name.
    func validateRestoredSession() async {
        guard let token else { return }
        // /auth/me both proves the token is live AND returns the account it
        // belongs to, so one call covers validation and restoring the display
        // name that a reinstall wiped.
        guard let url = URL(string: baseURL + "/auth/me") else { return }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await Core.data(for: request),
              let http = response as? HTTPURLResponse
        else {
            tvWarn("Session validation skipped — bridge unreachable", category: "auth")
            return
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            tvWarn("Restored session rejected (\(http.statusCode)) — signing out", category: "auth")
            TVRemoteLogger.logError(
                category: "auth", event: "restored_session_invalid",
                message: "HTTP \(http.statusCode)",
                detail: ["status": http.statusCode, "hadStoredUser": user != nil],
                authToken: token
            )
            logout()
            return
        }

        // Session is good — re-hydrate the account details. The token lives in
        // the Keychain and survives a reinstall; the user record lives in
        // UserDefaults and does NOT, so after a fresh install the profile card
        // showed a generic "Signed in" with no name even though the session
        // was perfectly valid and belonged to the right account. That reads
        // exactly like being signed into somebody else's account.
        let hadStoredUser = user != nil
        if (200..<300).contains(http.statusCode),
           let decoded = try? JSONDecoder().decode(TVUser.self, from: data) {
            user = decoded
            if let encoded = try? JSONEncoder().encode(decoded) {
                UserDefaults.standard.set(encoded, forKey: userKey)
            }
        }
        TVRemoteLogger.log(category: "auth", event: "restored_session_valid",
                           detail: ["hadStoredUser": hadStoredUser,
                                    "recoveredUser": user != nil && !hadStoredUser,
                                    "status": http.statusCode],
                           authToken: token)
    }

    func logout() {
        // Snapshot before clearing — the remote event's network call runs on
        // a later run-loop turn, after `token` below is already nil, so
        // without this the event would lose its user attribution entirely
        // (see TVRemoteLogger's authToken doc comment).
        let priorToken = token
        tvBreadcrumb("Logged out")
        tvLog("Logout", category: "auth")
        TVRemoteLogger.log(category: "auth", event: "logout", authToken: priorToken)
        token = nil
        user = nil
        TVKeychainTokenStore.delete(account: tokenKey)
        UserDefaults.standard.removeObject(forKey: userKey)
    }
}
