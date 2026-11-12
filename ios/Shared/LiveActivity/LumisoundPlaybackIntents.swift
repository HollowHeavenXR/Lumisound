import AppIntents
import Foundation
import WidgetKit

// MARK: - Transport buttons for widgets and the Live Activity
//
// Each is also a `LiveActivityIntent`: iOS lets an app update its Live
// Activity from the background while such an intent runs, but drops updates
// from an app that is merely playing audio in the background. So a skip from
// the Lock Screen updates the card at once (see `LiveActivityManager.flush`).
//
// Compiled into BOTH the app and the widget extension. That is what lets iOS
// run these in the app's own process: an `AudioPlaybackIntent` attached to a
// widget or Live Activity button is executed in the app (launching it in the
// background if it is not running) when the app target contains the same
// intent type.
//
// These lived in the widget extension alone and worked by posting a Darwin
// notification for the app to pick up. A Darwin notification only reaches a
// process that is running, and a paused app is suspended within seconds of
// leaving the foreground, so Play on the Lock Screen / Dynamic Island usually
// went nowhere: pause worked (audio keeps the app alive) and resume did not.
//
// The Darwin notification remains the fallback for when the intent does run in
// the extension, which is what an older app build installed alongside a newer
// widget would cause.

enum WidgetNotificationNames {
    static let togglePlayback = "com.lumisound.ios.widget.togglePlayback"
    static let skipNext       = "com.lumisound.ios.widget.skipNext"
    static let skipPrevious   = "com.lumisound.ios.widget.skipPrevious"
    static let toggleFavorite = "com.lumisound.ios.widget.toggleFavorite"
}

enum LumisoundPlaybackCommand: Sendable {
    case togglePlayback
    case skipNext
    case skipPrevious
    case toggleFavorite

    var darwinName: String {
        switch self {
        case .togglePlayback: return WidgetNotificationNames.togglePlayback
        case .skipNext:       return WidgetNotificationNames.skipNext
        case .skipPrevious:   return WidgetNotificationNames.skipPrevious
        case .toggleFavorite: return WidgetNotificationNames.toggleFavorite
        }
    }
}

/// Where a command goes once its intent runs.
@MainActor
enum LumisoundPlaybackCommandRouter {
    /// Installed by the app's player at launch; never set in the widget
    /// extension. Returns whether the command was carried out.
    static var handler: (@MainActor (LumisoundPlaybackCommand) -> Bool)?
    /// Installed by the app: waits until the widgets and Live Activity have
    /// been given the command's result. iOS redraws the Live Activity when
    /// the intent returns, so returning before the update has landed showed
    /// the old state until the next redraw (the delay after tapping pause).
    static var settle: (@MainActor () async -> Void)?

    static func perform(_ command: LumisoundPlaybackCommand) async {
        // Inside the app the player may still be starting: a button tapped
        // while the app was not running launches it to run this intent, and
        // the handler is installed when the player is created. Give that a
        // few seconds rather than dropping the tap.
        if !isAppExtension {
            for _ in 0..<50 where handler == nil {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        if let handler, handler(command) {
            await settle?()
            return
        }
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(command.darwinName as CFString),
            nil, nil, true
        )
    }

    private static var isAppExtension: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }
}

// MARK: - Toggle Playback

struct TogglePlaybackIntent: AudioPlaybackIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Toggle Playback"
    static let description = IntentDescription("Play or pause Lumisound.")
    static let openAppWhenRun: Bool = false
    static let isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        await LumisoundPlaybackCommandRouter.perform(.togglePlayback)
        return .result()
    }
}

// MARK: - Skip Previous

struct SkipPreviousIntent: AudioPlaybackIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip to Previous"
    static let description = IntentDescription("Skip to the previous track in Lumisound.")
    static let openAppWhenRun: Bool = false
    static let isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        await LumisoundPlaybackCommandRouter.perform(.skipPrevious)
        return .result()
    }
}

// MARK: - Skip Next

struct SkipNextIntent: AudioPlaybackIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip to Next"
    static let description = IntentDescription("Skip to the next track in Lumisound.")
    static let openAppWhenRun: Bool = false
    static let isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        await LumisoundPlaybackCommandRouter.perform(.skipNext)
        return .result()
    }
}

// MARK: - Toggle Favorite

/// Favorites/unfavorites the currently-playing track from a widget or the Live
/// Activity.
///
/// Writes an optimistic flag to the App Group first so the heart flips at once
/// even if the app cannot be reached, then routes the real toggle to the app,
/// whose authoritative value overwrites that guess (see
/// `AudioPlayerManager.toggleFavoriteFromWidget()`).
struct ToggleFavoriteIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Toggle Favorite"
    static let description = IntentDescription("Favorites or unfavorites the current track in Lumisound.")
    static let openAppWhenRun: Bool = false
    static let isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        if var snapshot = NowPlayingSnapshot.load() {
            snapshot.isFavorite.toggle()
            snapshot.save()
            WidgetCenter.shared.reloadAllTimelines()
        }

        await LumisoundPlaybackCommandRouter.perform(.toggleFavorite)
        return .result()
    }
}
