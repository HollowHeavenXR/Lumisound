import Foundation
import SwiftUI
import UIKit

extension AccountService {

    // MARK: - Public API

    func login(username: String, password: String, deviceName: String = UIDevice.current.name) async {
        appLog("Login attempt: \(username)", category: "account")
        errorMessage = nil
        pendingTOTPToken = nil
        struct Body: Encodable {
            let username: String
            let password: String
            let device_name: String
        }
        do {
            let data = try await makeRequest(
                "/auth/login",
                method: "POST",
                body: Body(username: username, password: password, device_name: deviceName)
            )
            // A 2FA-enabled account's password check alone doesn't return a
            // session (see /auth/login's doc comment on the bridge) — it
            // returns `requires_2fa`/`pending_token` instead, which the plain
            // `AuthResponse` shape below can't decode (no `user`/`token`
            // fields). Check for that shape FIRST rather than letting the
            // AuthResponse decode fail and land in the generic error path,
            // where this would previously have shown as an opaque decoding
            // error instead of prompting for a code.
            if let pending = try? JSONDecoder().decode(TOTPPendingResponse.self, from: data), pending.requires_2fa {
                pendingTOTPToken = pending.pending_token
                appLog("Login requires 2FA code: \(username)", category: "account")
                return
            }
            let response = try JSONDecoder().decode(AuthResponse.self, from: data)
            token = response.token
            currentUser = response.user
            isLoggedIn = true
            hasDateOfBirth = response.user.dateOfBirth != nil
            saveUserLocally(response.user)
            appLog("Login success: \(username) (id: \(response.user.id))", category: "account")
            await loadAvatar(forceRefresh: true)
            await refreshTOTPStatus()
        } catch let err as AccountError {
            appError("Login failed [\(err.statusCode)]: \(err.message)", category: "account")
            errorMessage = err.message
        } catch {
            appError("Login error: \(error.localizedDescription)", category: "account")
            errorMessage = error.localizedDescription
        }
    }

    /// Completes a login `login()` paused for a TOTP code — see
    /// `pendingTOTPToken`. Clears `pendingTOTPToken` on any outcome (success
    /// OR failure) other than a wrong code, since an expired/invalid pending
    /// token means the whole flow needs to restart from `login()`, not just
    /// a retry of this step; a wrong *code* is the one case worth letting
    /// the user simply try again without re-entering their password.
    func completeTOTPLogin(code: String, deviceName: String = UIDevice.current.name) async {
        guard let pending = pendingTOTPToken else { return }
        errorMessage = nil
        struct Body: Encodable {
            let pending_token: String
            let code: String
            let device_name: String
        }
        do {
            let data = try await makeRequest(
                "/auth/2fa/login",
                method: "POST",
                body: Body(pending_token: pending, code: code, device_name: deviceName)
            )
            let response = try JSONDecoder().decode(AuthResponse.self, from: data)
            token = response.token
            currentUser = response.user
            isLoggedIn = true
            hasDateOfBirth = response.user.dateOfBirth != nil
            pendingTOTPToken = nil
            saveUserLocally(response.user)
            appLog("2FA login success: \(response.user.username)", category: "account")
            await loadAvatar(forceRefresh: true)
            isTOTPEnabled = true
        } catch let err as AccountError {
            appError("2FA login failed [\(err.statusCode)]: \(err.message)", category: "account")
            errorMessage = err.message
            // 401 covers both "wrong code" (retry-worthy) and "pending token
            // expired" (not retry-worthy) per the bridge's /auth/2fa/login —
            // it doesn't distinguish them in the status code, so treat any
            // 401 here as retry-worthy (the common case) and only actually
            // clear the pending token on a definitively non-recoverable error.
            if err.statusCode != 401 {
                pendingTOTPToken = nil
            }
        } catch {
            appError("2FA login error: \(error.localizedDescription)", category: "account")
            errorMessage = error.localizedDescription
        }
    }

    func cancelTOTPLogin() {
        pendingTOTPToken = nil
        errorMessage = nil
    }

    func register(
        username: String,
        password: String,
        email: String?,
        displayName: String?
    ) async {
        appLog("Register attempt: \(username)", category: "account")
        errorMessage = nil
        struct Body: Encodable {
            let username: String
            let password: String
            let email: String?
            let display_name: String?
        }
        do {
            let data = try await makeRequest(
                "/auth/register",
                method: "POST",
                body: Body(
                    username: username,
                    password: password,
                    email: email.flatMap { $0.isEmpty ? nil : $0 },
                    display_name: displayName.flatMap { $0.isEmpty ? nil : $0 }
                )
            )
            let response = try JSONDecoder().decode(AuthResponse.self, from: data)
            token = response.token
            currentUser = response.user
            isLoggedIn = true
            hasDateOfBirth = response.user.dateOfBirth != nil
            saveUserLocally(response.user)
            appLog("Register success: \(username) (id: \(response.user.id))", category: "account")
            await loadAvatar(forceRefresh: true)
        } catch let err as AccountError {
            appError("Register failed [\(err.statusCode)]: \(err.message)", category: "account")
            errorMessage = err.message
        } catch {
            appError("Register error: \(error.localizedDescription)", category: "account")
            errorMessage = error.localizedDescription
        }
    }

    func logout() async {
        appLog("Logout: \(currentUser?.username ?? "?")", category: "account")
        errorMessage = nil
        await unregisterCurrentDeviceToken()
        if token != nil {
            _ = try? await makeRequest("/auth/logout", method: "POST", body: EmptyBody())
        }
        clearSession()
    }

    /// The signed-in account as the server has it now. The copy saved at sign
    /// in was otherwise never refreshed, so a username (or anything else)
    /// changed on the server or another device kept showing the old value.
    /// Runs on launch and on returning to the app, at most once a minute.
    func refreshMeIfStale(minInterval: TimeInterval = 60) async {
        if let last = lastMeRefresh, Date().timeIntervalSince(last) < minInterval { return }
        lastMeRefresh = Date()
        let before = currentUser
        await refreshMe()
        if let before, let now = currentUser, before.username != now.username || before.displayName != now.displayName {
            // Screens built from the social profile pick up the new name too.
            await SocialService.shared?.fetchMyProfile()
        }
    }

    func refreshMe() async {
        guard isLoggedIn else { return }
        do {
            let data = try await makeRequest("/auth/me")
            let user = try JSONDecoder().decode(AppUser.self, from: data)
            currentUser = user
            hasDateOfBirth = user.dateOfBirth != nil
            saveUserLocally(user)
            appLog("refreshMe: updated profile for \(user.username)", category: "account")
        } catch let err as AccountError where err.statusCode == 401 {
            appWarn("refreshMe: session expired, clearing", category: "account")
            clearSession()
        } catch {
            appWarn("refreshMe: \(error.localizedDescription) — using cached user", category: "account")
        }
    }

    /// Update the display name on the server and locally.
    func updateDisplayName(_ newName: String) async {
        guard isLoggedIn else { return }
        appLog("updateDisplayName: \"\(newName)\"", category: "account")
        errorMessage = nil
        struct Body: Encodable { let display_name: String }
        do {
            let data = try await makeRequest("/auth/me", method: "PUT", body: Body(display_name: newName))
            let user = try JSONDecoder().decode(AppUser.self, from: data)
            currentUser = user
            hasDateOfBirth = user.dateOfBirth != nil
            saveUserLocally(user)
            appLog("updateDisplayName: success", category: "account")
        } catch let err as AccountError {
            appError("updateDisplayName failed [\(err.statusCode)]: \(err.message)", category: "account")
            errorMessage = err.message
        } catch {
            appError("updateDisplayName error: \(error.localizedDescription)", category: "account")
            errorMessage = error.localizedDescription
        }
    }
}
