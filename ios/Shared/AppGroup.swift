import Foundation
import Security

/// Resolves the App Group container identifier this process was *actually*
/// signed with, instead of assuming the literal `group.com.lumisound.ios`.
///
/// Free/personal-team signing (the norm for SideStore/AltStore sideloads,
/// since a paid Apple Developer Program membership isn't required for it)
/// can't reserve that literal App Group ID globally, so the signing tool
/// suffixes it with the team identifier instead (e.g.
/// `group.com.lumisound.ios.2HB39W9VS3`) — confirmed from an actual embedded
/// provisioning profile. The app, widget, and watch targets are all resigned
/// together and so all receive the *same* suffix — but code that hardcodes
/// the unsuffixed literal ends up asking `UserDefaults`/`FileManager` for a
/// suite name that doesn't match what was actually granted, which is why
/// widgets silently stay on their placeholder on sideloaded builds even
/// though the entitlement is present.
///
/// `SecTaskCopyValueForEntitlement` (reading our own entitlements directly)
/// isn't part of Security.framework's public Swift module map on iOS, so
/// instead this recovers the team identifier the same way many apps do:
/// iOS tags any keychain item saved without an explicit access group with
/// `"<TeamID>.<bundleID>"`, and `kSecAttrAccessGroup` is documented, public
/// API — so a throwaway keychain probe reveals our own team identifier
/// regardless of how (or by whom) the build was signed.
enum AppGroup {
    static let literal = "group.com.lumisound.ios"

    /// Resolved once per process. The keychain probe fails while the device
    /// is locked (Live Activities and Lock Screen widgets render then), which
    /// sent those surfaces to the wrong group: no artwork, or no data at all.
    /// So the signed group is read from the embedded provisioning profile
    /// first, then from this process's own cached answer, and the keychain
    /// is only the last resort.
    static let id: String = {
        let fm = FileManager.default
        func usable(_ id: String) -> Bool { fm.containerURL(forSecurityApplicationGroupIdentifier: id) != nil }
        if usable(literal) { return literal }

        let cacheKey = "AppGroup.resolvedID"
        var candidates = profileGroups()
        if let cached = UserDefaults.standard.string(forKey: cacheKey) { candidates.append(cached) }
        if let teamID = discoverTeamIdentifier() { candidates.append("\(literal).\(teamID)") }
        for id in candidates where usable(id) {
            UserDefaults.standard.set(id, forKey: cacheKey)
            return id
        }
        // Not provably usable: still prefer what the profile says over the
        // literal, since that is what this build was signed with.
        return candidates.first ?? literal
    }()

    /// App Groups granted by this bundle's embedded.mobileprovision that
    /// belong to Lumisound (the literal or a suffixed form). Readable while
    /// the device is locked, unlike the keychain.
    private static func profileGroups() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else { return [] }
        return groups.filter { $0 == literal || $0.hasPrefix(literal + ".") }
    }

    private static func discoverTeamIdentifier() -> String? {
        let probeQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "AppGroupTeamIdentifierProbe",
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        var status = SecItemCopyMatching(probeQuery as CFDictionary, &result)

        if status == errSecItemNotFound {
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: "AppGroupTeamIdentifierProbe",
                kSecValueData as String: Data(),
                // Readable on the Lock Screen too (after the first unlock).
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            SecItemAdd(addQuery as CFDictionary, nil)
            status = SecItemCopyMatching(probeQuery as CFDictionary, &result)
        }

        guard status == errSecSuccess,
              let attributes = result as? [String: Any],
              let accessGroup = attributes[kSecAttrAccessGroup as String] as? String,
              let dotIndex = accessGroup.firstIndex(of: ".")
        else { return nil }

        return String(accessGroup[..<dotIndex])
    }
}
