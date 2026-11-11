import SwiftUI
import UIKit

// MARK: - StrataSettings
//
// The Strata settings and account screens are composed in Rust
// (strata.rs `settings` / `account`). This adapter is the only Swift part:
// it reads each key's current value for Rust (`values`) and writes a
// changed value back where the app keeps it (`apply`), through the same
// services the classic settings screens use.

@MainActor
enum StrataSettings {
    static func values(player: AudioPlayerManager?, account: AccountService?, sleep: SleepTimerService?, cloudCount: Int) -> [String: StrataValue] {
        var v: [String: StrataValue] = [:]
        let d = UserDefaults.standard
        func flag(_ k: String, _ b: Bool) { v[k] = .flag(on: b) }
        func num(_ k: String, _ n: Double) { v[k] = .number(value: n) }
        func text(_ k: String, _ s: String) { v[k] = .text(value: s) }

        if let a = player?.audioSettings {
            flag("audio.eq", a.equalizerEnabled)
            text("audio.eqPreset", a.eqPreset.rawValue)
            flag("audio.autoEQ", a.autoEQEnabled)
            flag("audio.bassBoost", a.bassBoostEnabled)
            num("audio.bassBoostGain", Double(a.bassBoostGain))
            flag("audio.reverb", a.reverbEnabled)
            text("audio.reverbPreset", a.reverbPreset.rawValue)
            num("audio.reverbMix", Double(a.reverbWetDryMix))
            flag("audio.spatial", a.spatialAudioEnabled == true)
            flag("audio.eightD", a.eightDAudioEnabled == true)
            num("audio.speed", Double(a.speed))
            num("audio.pitch", Double(a.pitchSemitones))
            flag("audio.replayGain", a.replayGainEnabled)
            flag("audio.night", a.nightModeEnabled == true)
            flag("audio.mono", a.monoAudioEnabled == true)
            flag("audio.gapless", a.gaplessEnabled)
            flag("audio.smartCrossfade", a.smartCrossfadeEnabled)
            flag("audio.crossfade", a.crossfadeEnabled)
            num("audio.crossfadeDuration", a.crossfadeDuration)
            text("audio.crossfadeCurve", (a.crossfadeCurve ?? .equalPower).rawValue)
            flag("audio.haptics", a.musicHapticsEnabled == true)
        }
        flag("intro.skip", SilenceTrimService.shared?.isEnabled ?? d.bool(forKey: "silenceTrim.enabled"))
        flag("shuffle.smart", d.object(forKey: SmartShuffle.settingKey) as? Bool ?? true)
        flag("radio.auto", player?.autoRadioEnabled ?? false)
        text("radio.mode", d.string(forKey: "radio_mode") ?? "balanced")
        text("haptics.strength", d.string(forKey: MusicHapticsService.strengthKey) ?? "balanced")
        flag("library.autoBackup", d.bool(forKey: "autoCloudBackup"))
        flag("downloads.wifiOnly", d.bool(forKey: "wifiOnlyDownloads.enabled"))
        num("ytdlp.fragments", Double(d.object(forKey: "ytdlp_concurrent_fragments") as? Int ?? 8))
        flag("ytdlp.aria2", d.bool(forKey: "ytdlp_use_aria2"))
        text("ui.edition", InterfaceEdition.current.rawValue)
        text("strata.accent", StrataStore.accentHex())
        flag("ui.reduceMotion", d.bool(forKey: "app_reduce_motion"))
        flag("car.mode", d.bool(forKey: "carModeEnabled"))
        num("sleep.remaining", (sleep?.isActive ?? false) ? (sleep?.remainingSeconds ?? 0) : 0)
        text("app.version", "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
        if let account, account.isLoggedIn, let u = account.currentUser {
            flag("account.signedIn", true)
            text("account.username", u.username)
            text("account.displayName", u.displayName ?? "")
            text("account.email", u.email ?? "")
            flag("account.shareListening", u.shareListeningActivity)
            num("account.cloudCount", Double(cloudCount))
        }
        return v
    }

    /// Write a changed setting back.
    static func apply(key: String, value: StrataValue, player: AudioPlayerManager?, library: LibraryManager?, account: AccountService?, sleep: SleepTimerService?) {
        let d = UserDefaults.standard
        let on: Bool = { if case .flag(let b) = value { return b }; return false }()
        let n: Double = { if case .number(let x) = value { return x }; return 0 }()
        let t: String = { if case .text(let s) = value { return s }; return "" }()
        func audio(_ change: (inout AudioSettings) -> Void) {
            guard let player else { return }
            var s = player.audioSettings
            change(&s)
            player.audioSettings = s
        }
        switch key {
        case "audio.eq": audio { $0.equalizerEnabled = on }
        case "audio.eqPreset": if let p = EQPreset(rawValue: t) { player?.applyEQPreset(p); audio { $0.equalizerEnabled = true } }
        case "audio.autoEQ": audio { $0.autoEQEnabled = on }
        case "audio.bassBoost": audio { $0.bassBoostEnabled = on }
        case "audio.bassBoostGain": audio { $0.bassBoostGain = Float(n) }
        case "audio.reverb": audio { $0.reverbEnabled = on }
        case "audio.reverbPreset": if let p = ReverbRoomPreset(rawValue: t) { audio { $0.reverbPreset = p } }
        case "audio.reverbMix": audio { $0.reverbWetDryMix = Float(n) }
        case "audio.spatial": audio { $0.spatialAudioEnabled = on }
        case "audio.eightD": audio { $0.eightDAudioEnabled = on }
        case "audio.speed": audio { $0.speed = Float(n) }
        case "audio.pitch": audio { $0.pitchSemitones = Float(n) }
        case "audio.replayGain": audio { $0.replayGainEnabled = on }
        case "audio.night": audio { $0.nightModeEnabled = on }
        case "audio.mono": audio { $0.monoAudioEnabled = on }
        case "audio.gapless": audio { $0.gaplessEnabled = on }
        case "audio.smartCrossfade":
            // One transition strategy at a time (as in classic Settings).
            audio { $0.smartCrossfadeEnabled = on; if on { $0.crossfadeEnabled = false } }
        case "audio.crossfade": audio { $0.crossfadeEnabled = on; if on { $0.smartCrossfadeEnabled = false } }
        case "audio.crossfadeDuration": audio { $0.crossfadeDuration = n }
        case "audio.crossfadeCurve": if let c = CrossfadeCurve(rawValue: t) { audio { $0.crossfadeCurve = c } }
        case "audio.haptics": audio { $0.musicHapticsEnabled = on }
        case "intro.skip":
            if let svc = SilenceTrimService.shared { svc.isEnabled = on } else { d.set(on, forKey: "silenceTrim.enabled") }
        case "shuffle.smart": d.set(on, forKey: SmartShuffle.settingKey)
        case "radio.auto": player?.autoRadioEnabled = on
        case "radio.mode": d.set(t, forKey: "radio_mode")
        case "haptics.strength": d.set(t, forKey: MusicHapticsService.strengthKey)
        case "library.autoBackup": d.set(on, forKey: "autoCloudBackup")
        case "downloads.wifiOnly": d.set(on, forKey: "wifiOnlyDownloads.enabled")
        case "ytdlp.fragments": d.set(Int(n), forKey: "ytdlp_concurrent_fragments")
        case "ytdlp.aria2": d.set(on, forKey: "ytdlp_use_aria2")
        case "library.rescan":
            library?.scanLocalDocuments()
            ToastCenter.shared.show("Rescanning your library", icon: "arrow.clockwise")
        case "ui.edition":
            if let e = InterfaceEdition(rawValue: t) { InterfaceEdition.select(e) }
        case "strata.accent":
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: UIColor(Color(strataHex: t)), requiringSecureCoding: true) {
                d.set(data, forKey: "strata_accent_color_data")
            }
            StrataStore.shared.refreshTheme()
        case "ui.reduceMotion": d.set(on, forKey: "app_reduce_motion")
        case "car.mode": d.set(on, forKey: "carModeEnabled")
        case "sleep.minutes":
            if n <= 0 { sleep?.cancel() } else { sleep?.start(duration: n * 60) }
        case "account.shareListening":
            if let account { Task { await account.setShareListeningActivity(on) } }
        default:
            appWarn("Strata: unknown setting \(key)", category: "ui")
        }
    }
}
