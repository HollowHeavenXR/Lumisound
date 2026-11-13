import Foundation
import UIKit
import SwiftUI

@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    @Published private(set) var latestVersion: String? = nil
    @Published private(set) var updateAvailable: Bool = false
    @Published private(set) var isChecking: Bool = false
    // swiftlint:disable:next force_unwrapping
    private static let fallbackReleaseURL = URL(string: "https://github.com/VoxeliseStudios/Lumisound/releases/latest")!
    @Published private(set) var releasePageURL: URL = UpdateService.fallbackReleaseURL
    @Published private(set) var directDownloadURL: URL? = nil

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    // MARK: - Status display helpers

    var updateStatusText: String {
        if isChecking { return "Checking…" }
        if updateAvailable, let v = latestVersion { return "v\(v) available" }
        return "Up to date"
    }

    var updateStatusIcon: String {
        if isChecking { return "arrow.clockwise" }
        if updateAvailable { return "arrow.down.circle.fill" }
        return "checkmark.circle.fill"
    }

    var updateStatusColor: Color {
        if updateAvailable { return AppTheme.warning }
        return AppTheme.success
    }

    private init() {}

    func openReleasePage() {
        // Use the direct IPA download URL when available so Safari immediately
        // starts the download instead of navigating to the release web page.
        let target = directDownloadURL ?? releasePageURL
        UIApplication.shared.open(target)
    }

    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        appLog("checkForUpdates: current=\(currentVersion)", category: "network")

        // Routed through the bridge (see ios-bridge/main.py's
        // /api/app/latest-release) rather than hitting GitHub directly —
        // the Lumisound repo is private, and an unauthenticated request
        // from the client always 404s against a private repo's API (GitHub
        // doesn't even reveal it exists to an unauthenticated caller). The
        // bridge holds a read-only PAT server-side and proxies the same
        // releases-list JSON shape this function already parses below, so
        // nothing past this request itself needed to change.
        guard let account = AccountService.shared else {
            appWarn("checkForUpdates: AccountService not available", category: "network")
            return
        }

        do {
            let data = try await account.makeRequest("/api/app/latest-release")
            guard let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                appWarn("checkForUpdates: unexpected response format", category: "network")
                return
            }

            // Look for the best iOS-specific release first (tag starts with "ios/v"),
            // falling back to any tag starting with "v".
            var bestTag: String? = nil
            var bestPageURL: URL? = nil
            var bestIPADownloadURL: URL? = nil

            for release in releases {
                guard let tagName = release["tag_name"] as? String,
                      let htmlURL = release["html_url"] as? String
                else { continue }

                let isDraft = release["draft"] as? Bool ?? false
                let isPrerelease = release["prerelease"] as? Bool ?? false
                guard !isDraft, !isPrerelease else { continue }

                if tagName.hasPrefix("ios/v") {
                    bestTag = String(tagName.dropFirst("ios/v".count))
                    bestPageURL = URL(string: htmlURL)
                    // Scan release assets for the IPA direct download link.
                    if let assets = release["assets"] as? [[String: Any]] {
                        for asset in assets {
                            if let name = asset["name"] as? String,
                               name.lowercased().hasSuffix(".ipa"),
                               let urlStr = asset["browser_download_url"] as? String,
                               let url = URL(string: urlStr) {
                                bestIPADownloadURL = url
                                break
                            }
                        }
                    }
                    break   // ios/v prefix is preferred; stop on first match.
                }

                if tagName.hasPrefix("v"), bestTag == nil {
                    bestTag = String(tagName.dropFirst(1))
                    bestPageURL = URL(string: htmlURL)
                    // Scan assets for this fallback release too.
                    if let assets = release["assets"] as? [[String: Any]] {
                        for asset in assets {
                            if let name = asset["name"] as? String,
                               name.lowercased().hasSuffix(".ipa"),
                               let urlStr = asset["browser_download_url"] as? String,
                               let url = URL(string: urlStr) {
                                bestIPADownloadURL = url
                                break
                            }
                        }
                    }
                }
            }

            guard let versionString = bestTag else {
                appLog("checkForUpdates: no suitable release found in \(releases.count) release(s)", category: "network")
                return
            }

            latestVersion = versionString
            if let pageURL = bestPageURL {
                releasePageURL = pageURL
            }
            directDownloadURL = bestIPADownloadURL
            updateAvailable = isNewerVersion(versionString, than: currentVersion)
            appLog("checkForUpdates: latest=\(versionString) updateAvailable=\(updateAvailable)", category: "network")
        } catch {
            appWarn("checkForUpdates: network/parse error: \(error.localizedDescription)", category: "network")
        }
    }

    // MARK: - Version Comparison

    /// Returns `true` if `candidate` is strictly newer than `current`.
    /// Compares dot-separated integer components (e.g. "1.2.3" > "1.2.0").
    private func isNewerVersion(_ candidate: String, than current: String) -> Bool {
        let candidateParts = versionComponents(candidate)
        let currentParts   = versionComponents(current)

        let maxLen = max(candidateParts.count, currentParts.count)
        for i in 0..<maxLen {
            let c = i < candidateParts.count ? candidateParts[i] : 0
            let s = i < currentParts.count   ? currentParts[i]   : 0
            if c > s { return true }
            if c < s { return false }
        }
        return false  // equal versions
    }

    private func versionComponents(_ version: String) -> [Int] {
        version.split(separator: ".").compactMap { Int($0) }
    }
}
