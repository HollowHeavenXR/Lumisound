import Foundation

/// Syncs the interface style (Settings → Appearance) with the account so a
/// new device picks up the same look. Quiet on failure: the local choice
/// always wins until the server has one.
extension AccountService {
    struct AppearanceSync: Codable {
        let style: String?
        let density: String?
    }

    func pushAppearance(style: String, density: String) {
        guard isLoggedIn else { return }
        Task { @MainActor in
            do {
                _ = try await makeRequest("/user/appearance", method: "PUT",
                                          body: AppearanceSync(style: style, density: density))
            } catch {
                appLog("pushAppearance failed: \(error.localizedDescription)", category: "account")
            }
        }
    }

    func pullAppearance() async {
        guard isLoggedIn else { return }
        guard let data = try? await makeRequest("/user/appearance"),
              let sync = try? JSONDecoder().decode(AppearanceSync.self, from: data),
              let style = sync.style else { return }
        let density: Density = switch sync.density {
        case "compact": .compact
        case "roomy": .roomy
        default: .regular
        }
        let a = Appearance.shared
        if a.styleID != style || a.density != density {
            a.apply(style: style, density: density, push: false)
        }
    }

    /// Called once at start-up: local changes go up, the account's choice comes down.
    func startAppearanceSync() {
        Appearance.shared.onChange = { [weak self] style, density in
            self?.pushAppearance(style: style, density: density)
        }
        Task { @MainActor [weak self] in await self?.pullAppearance() }
    }
}
