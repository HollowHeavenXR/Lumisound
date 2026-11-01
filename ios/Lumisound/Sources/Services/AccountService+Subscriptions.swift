import Foundation
import SwiftUI
import UIKit

extension AccountService {

    // MARK: - Artist/Channel Subscriptions

    /// Lists the user's subscribed channels.
    func fetchSubscriptions() async -> [ArtistSubscription] {
        guard isLoggedIn else { return [] }
        do {
            let data = try await makeRequest("/user/subscriptions")
            return try JSONDecoder().decode([ArtistSubscription].self, from: data)
        } catch let err as AccountError {
            errorMessage = err.message
            return []
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// Subscribes to a channel/artist URL (YouTube or SoundCloud).
    func addSubscription(channelUrl: String, channelName: String?) async -> Bool {
        guard isLoggedIn else { return false }
        struct Body: Encodable { let channel_url: String; let channel_name: String? }
        do {
            _ = try await makeRequest("/user/subscriptions", method: "POST", body: Body(channel_url: channelUrl, channel_name: channelName))
            return true
        } catch let err as AccountError {
            errorMessage = err.message
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Unsubscribes from a channel.
    func removeSubscription(id: String) async -> Bool {
        guard isLoggedIn else { return false }
        do {
            _ = try await makeRequest("/user/subscriptions/\(id)", method: "DELETE")
            return true
        } catch let err as AccountError {
            errorMessage = err.message
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Partial-updates a subscription's auto-download opt-in (+ optional
    /// destination folder), notification mute, and/or category — only
    /// non-nil parameters are changed server-side (Feature: subscriptions-expansion).
    @discardableResult
    func updateSubscriptionSettings(
        id: String,
        autoDownload: Bool? = nil,
        destinationFolder: String? = nil,
        notificationsMuted: Bool? = nil,
        category: String? = nil
    ) async -> Bool {
        guard isLoggedIn else { return false }
        struct Body: Encodable {
            let auto_download: Bool?
            let destination_folder: String?
            let notifications_muted: Bool?
            let category: String?
        }
        do {
            _ = try await makeRequest(
                "/user/subscriptions/\(id)", method: "PATCH",
                body: Body(auto_download: autoDownload, destination_folder: destinationFolder,
                           notifications_muted: notificationsMuted, category: category)
            )
            return true
        } catch let err as AccountError {
            errorMessage = err.message
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Resolves a YouTube channel URL/@handle/search term to a real channel
    /// (id, title, thumbnail) via POST /youtube/resolve-channel.
    func resolveYoutubeChannel(query: String) async -> ResolvedChannel? {
        guard isLoggedIn else { return nil }
        struct Body: Encodable { let query: String }
        do {
            let data = try await makeRequest("/youtube/resolve-channel", method: "POST", body: Body(query: query))
            return try JSONDecoder().decode(ResolvedChannel.self, from: data)
        } catch let err as AccountError {
            errorMessage = err.message
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Fetches recent uploads for a resolved channel (GET /youtube/channel-uploads).
    func fetchChannelUploads(channelId: String, limit: Int = 10) async -> [StreamTrack] {
        guard isLoggedIn else { return [] }
        do {
            let data = try await makeRequest("/youtube/channel-uploads?channel_id=\(channelId)&limit=\(limit)")
            return try JSONDecoder().decode([StreamTrack].self, from: data)
        } catch let err as AccountError {
            errorMessage = err.message
            return []
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// Checks a channel for new uploads since the last check, returning any new tracks found.
    func checkSubscription(id: String) async -> [StreamTrack] {
        guard isLoggedIn else { return [] }
        do {
            let data = try await makeRequest("/user/subscriptions/\(id)/check", method: "POST")
            return try JSONDecoder().decode(SubscriptionCheckResult.self, from: data).newTracks
        } catch let err as AccountError {
            errorMessage = err.message
            return []
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// Checks one subscription for new uploads and, if it has auto-download
    /// enabled, downloads any new tracks straight into the library —
    /// bounded-concurrency, mirroring `TrackedPlaylistStore.runAutoDownloads`
    /// (itself matching the bridge's own `_YTDLP_SEMAPHORE(4)`). Falls back
    /// to a plain check (no download) if `streaming`/`library` aren't
    /// supplied. Always returns the new tracks either way, same as
    /// `checkSubscription`, so callers can still show them in the UI.
    @discardableResult
    func checkSubscriptionAndAutoDownload(
        _ subscription: ArtistSubscription,
        streaming: StreamingService? = nil,
        library: LibraryManager? = nil
    ) async -> [StreamTrack] {
        let newTracks = await checkSubscription(id: subscription.id)
        if subscription.autoDownload, !newTracks.isEmpty, let streaming, let library {
            await Self.autoDownloadNewTracks(newTracks, for: subscription, streaming: streaming, library: library)
        }
        return newTracks
    }

    /// Checks every subscribed channel for new uploads, one after another
    /// (each check is its own request; the server creates the in-app
    /// notification for any new track — unless muted — same as tapping
    /// "Check Now" per channel), auto-downloading new tracks for any
    /// subscription that has that opt-in enabled. Used by both the
    /// Subscriptions screen's "Check All" and `BackgroundRefreshService`'s
    /// periodic background run. Returns each subscription's new tracks,
    /// keyed by subscription id, so callers can update their UI without a
    /// second round of requests.
    @discardableResult
    func checkAllSubscriptions(
        streaming: StreamingService? = nil,
        library: LibraryManager? = nil
    ) async -> [String: [StreamTrack]] {
        guard isLoggedIn else { return [:] }
        let subscriptions = await fetchSubscriptions()
        var results: [String: [StreamTrack]] = [:]
        for subscription in subscriptions {
            results[subscription.id] = await checkSubscriptionAndAutoDownload(
                subscription, streaming: streaming, library: library
            )
        }
        return results
    }

    /// Auto-download concurrency cap — mirrors `TrackedPlaylistStore`'s own
    /// constant (which mirrors the bridge's `_YTDLP_SEMAPHORE`): the
    /// bridge already caps itself at that many concurrent yt-dlp processes
    /// GLOBALLY, so sending that many at once (instead of 1) is what
    /// actually lets this client reach that existing server-side capacity.
    /// Dropped 4 -> 2 alongside _YTDLP_SEMAPHORE — see TrackedPlaylistStore's
    /// matching constant for why.
    private static let subscriptionAutoDownloadConcurrency = 2

    /// Downloads `tracks` into the library for one auto-download-enabled
    /// subscription, deduping against what's already there and running up to
    /// `subscriptionAutoDownloadConcurrency` downloads at once. Mirrors
    /// `TrackedPlaylistStore.runAutoDownloads`'s task-group pattern exactly.
    private static func autoDownloadNewTracks(
        _ tracks: [StreamTrack],
        for subscription: ArtistSubscription,
        streaming: StreamingService,
        library: LibraryManager
    ) async {
        await library.scanLocalDocumentsAsync(userInitiated: false)
        let index = await library.localCopyIndex()
        let toGet = index.missing(candidates: tracks.map(\.remoteCandidate)).map { tracks[Int($0)] }
        guard !toGet.isEmpty else { return }

        let destinationDir = StreamingService.downloadDirectory(forFolderName: subscription.destinationFolder)
        let existingSongsSnapshot = library.allSongs
        var got = 0
        await withTaskGroup(of: Bool.self) { group in
            var nextIndex = 0
            func startNext() {
                guard nextIndex < toGet.count else { return }
                let track = toGet[nextIndex]
                nextIndex += 1
                group.addTask {
                    do {
                        _ = try await streaming.downloadToLibrary(
                            track: track,
                            destinationDir: destinationDir,
                            existingSongs: existingSongsSnapshot,
                            destinationFolderName: subscription.destinationFolder,
                            reportExistingAsSkipped: true
                        )
                        return true
                    } catch StreamingError.alreadyDownloaded {
                        return false
                    } catch {
                        // Silent — this runs from a background check; the
                        // next scheduled check will simply retry it, same as
                        // TrackedPlaylistStore.runAutoDownloads.
                        return false
                    }
                }
            }
            for _ in 0..<min(subscriptionAutoDownloadConcurrency, toGet.count) { startNext() }
            for await success in group {
                if success { got += 1 }
                startNext()
            }
        }

        if got > 0 {
            library.scanLocalDocuments()
            let name = subscription.channelName ?? subscription.channelUrl
            ToastCenter.shared.show(
                "Auto-downloaded \(got) new track\(got == 1 ? "" : "s") from \"\(name)\"",
                category: .download
            )
        }
    }

    // MARK: - New Releases Feed

    /// Fetches the aggregated "New Releases" feed — every new upload
    /// discovered across all subscriptions (via on-demand checks or the
    /// bridge's own background polling loop), newest first.
    func fetchSubscriptionFeed(unreadOnly: Bool = false, limit: Int = 50) async -> [SubscriptionFeedItem] {
        guard isLoggedIn else { return [] }
        do {
            let data = try await makeRequest("/user/subscriptions/feed?limit=\(limit)&unread_only=\(unreadOnly)")
            return try JSONDecoder().decode([SubscriptionFeedItem].self, from: data)
        } catch let err as AccountError {
            errorMessage = err.message
            return []
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// Marks one feed item read (e.g. after the user taps it to play).
    func markSubscriptionFeedItemRead(id: String) async {
        guard isLoggedIn else { return }
        _ = try? await makeRequest("/user/subscriptions/feed/\(id)/read", method: "POST")
    }

    /// Marks every unread feed item read.
    func markAllSubscriptionFeedRead() async {
        guard isLoggedIn else { return }
        _ = try? await makeRequest("/user/subscriptions/feed/read-all", method: "POST")
    }

    /// Dismisses (deletes) one feed item.
    @discardableResult
    func dismissSubscriptionFeedItem(id: String) async -> Bool {
        guard isLoggedIn else { return false }
        do {
            _ = try await makeRequest("/user/subscriptions/feed/\(id)", method: "DELETE")
            return true
        } catch {
            return false
        }
    }
}
