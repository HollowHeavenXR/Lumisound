# ios — to do

Full history and decisions: [`../RUST-PORT.md`](../RUST-PORT.md). Swift is views + app shell only.

## Done (2026-11-07)
- Library Health > Listening > Often Skipped (`Views/OftenSkippedView.swift`).
- Skip history sync on start / every 20 min / backgrounding (`Services/AccountService+SkipSync.swift`).

## Done (2026-11-08)
- `Services/MusicHapticsService.swift`: Core Haptics player for the core's haptic score; Settings feel picker.
- `Services/SilenceTrimAnalyzer.swift` / `SilenceTrimService.swift`: core intro detector, engine opens tracks at the music.
- `LumisoundTV/Sources/TVAudioSettings.swift`: TVSilenceTrim on the core detector.

## Open
- Phase H: delete superseded Swift (AVAudioEngine graph etc.).
- tvOS/watchOS: show Often Skipped / use Smart Shuffle there too.
- Verify Music Haptics feel and timing on device (AirPods vs speaker latency).

## Done (2026-11-09)
- `Services/RadioService.swift`: Lumisound Radio sessions (start/refill/feedback), mode picker on Auto-Radio long-press.
- `Services/HapticsBrainService.swift`: background observation of every track + global model sync.
- Smart Crossfade on the core Blend planner (`queueRustBlendNext`).
- `Views/Components/PanningArtwork.swift`: thumbnail slide no longer freezes.
- Aria lyrics poll deadline 15 min (server-side engine).

## Open
- Strata interface (Rust-composed screens + generic SwiftUI renderer).
