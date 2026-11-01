# Lumisound for iOS

A full-featured, privacy-respecting music player built with SwiftUI and AVFoundation, for iPhone/iPad, Apple Watch, and Apple TV. Stream from YouTube and SoundCloud, manage your personal cloud library, apply spatial 8D audio and a 10-band EQ, listen together over SharePlay, and keep everything synced across devices with a free account.

This directory is one `xcodegen` project with five targets: `Lumisound` (iPhone/iPad),
`LumisoundWidget` (Home/Lock Screen/StandBy + Live Activity), `LumisoundWatch` + its own
`LumisoundWatchWidget`, and `LumisoundTV`.

---

## Features

See the [top-level README](../README.md) for the full feature list. Short version:

| Category | Details |
|---|---|
| **Home** | A customizable dashboard tab — reorderable/hideable shelves (Recently Added, Mixes, Genres, Friends Activity, Similar Listeners, and more), a custom greeting, and a dashboard-only accent color |
| **Playback** | Gapless, crossfade (manual or beatmatched Smart Auto Crossfade), AB repeat, sleep timer, sleep/wake alarm, variable speed & pitch, AI DJ Mode |
| **Audio FX** | 10-band EQ (+ Auto EQ) and 23 audio effects (8D spatial audio with speed control, nightcore, vaporwave, karaoke…) |
| **Library** | Local files, Apple Music library, folder/album organisation by directory name, AcoustID-based duplicate finder & corrupt file finder |
| **Podcasts** | Search, subscribe, chapters, offline downloads, auto-download, OPML import/export |
| **Streaming** | YouTube & SoundCloud search, stream, download, Pending Imports visibility — via bridge server |
| **Personal Cloud Library** | Upload your own audio files to your personal server folder; play & manage from anywhere |
| **Account** | Free accounts on the shared server — sync playlists, settings, play history, and favourites; shareable Rewind recap cards |
| **Friends & Profiles** | Add friends, see live online/now-playing status, a public profile page, and a Listening Twin match |
| **Listen Together** | SharePlay sync plus a shared suggest-and-vote Up Next queue |
| **Extras** | Needle Drop (a music-guessing mini-game) and Time Capsules (songs + a note, locked until a future date) |
| **Visuals** | Gallery background (slideshow with transitions), 25 Now Playing artwork styles plus a custom style editor, synced lyrics |
| **Lua Theme Presets** | 10 complete, swappable Lua-scripted presets (Settings → Appearance → Lua Theme Presets) — each one script sets colors, fonts, panel/glass style, feature flags, and Library sort/display defaults in one tap |
| **Now Playing** | Full transport controls, Up Next queue, lock-screen & headphone controls, CarPlay, Siri Shortcuts, Focus Filter |
| **Companion apps** | A full Apple Watch app and Apple TV app, both signed into the same account as the phone |

---

## Installation (iOS — no Jailbreak required)

### Option A — SideStore or AltStore (recommended for auto-updates)

Either app can add the same source and will keep Lumisound updated automatically. [SideStore](https://sidestore.io/) is the easier pick if you don't want to keep a computer running AltServer in the background — it refreshes itself on-device.

1. Install [SideStore](https://sidestore.io/) or [AltStore](https://altstore.io/) on your iPhone.
2. In the app → **Sources**, add:
   ```
   https://raw.githubusercontent.com/HollowHeavenXR/Lumisound/main/ios/altstore-source.json
   ```
3. Find **Lumisound** in the Browse tab and tap **Install**.
4. Updates appear automatically when a new version ships.

### Option B — Sideloadly / manual IPA

1. Download the latest `Lumisound-{version}-unsigned.ipa` from the [Releases page](https://github.com/HollowHeavenXR/Lumisound/releases/latest).
2. Install with [Sideloadly](https://sideloadly.io/), [AltServer](https://altstore.io/), or any IPA signer.

---

## The Bridge Server

Lumisound connects to a FastAPI bridge server that powers YouTube/SoundCloud search and streaming, the personal cloud library, and account sync.

### Where the server lives

The app ships pointed at the shared server running at:

```
https://lumisound-bridge.xenusanimations.studio
```

This is a static Cloudflare Tunnel domain running on the developer's machine. It is always on and accessible from anywhere without home Wi-Fi. You do not need to run your own server to use Lumisound — just create a free account (see below).

### Creating your account

Accounts are created directly in the app:

1. Open **Lumisound** — on first launch the welcome prompt appears.
2. Tap **Create Account**, enter a username and password (email optional).
3. Your playlists, favourites, audio settings, and personal cloud library are now synced to the server.

To log in on another device: reopen the app → tap **Log In** → enter your credentials.

> **No email required.** Username and password are enough. You can add an email later in Settings → Account.

### Accessing your personal music library

After logging in, open **Search → My Library**. You can:

- Tap **Upload Music to Server** to send local audio files from your device to your personal folder.
- Organise files into subfolders — folder names become album names in the library view.
- Play, stream, or delete files directly from the app.

### Self-hosting the bridge server

If you want to run your own server (for a private instance or extra storage):

The server is the Rust bridge in `rust/bridge` (built by `rust/Dockerfile`); `ios-bridge/` holds the deploy files.

```bash
cd ios-bridge
cp .env.example .env          # fill in DB creds and JWT secret
docker compose up -d --build
```

Then in **Lumisound → Settings → Streaming** set the Bridge URL to your server address. Point `SERVER_MUSIC_DIR` and `USER_MUSIC_DIR` environment variables to your music directories.

See [ios-bridge/README.md](../ios-bridge) for full server configuration.

---

## Build from Source (macOS only)

```bash
# Prerequisites: Xcode, XcodeGen, Rust (https://rustup.rs)
brew install xcodegen

ios/scripts/build-core.sh  # builds rust/core -> ios/RustCore (LumisoundCore.xcframework + Swift API)
cd ios
xcodegen generate          # generates Lumisound.xcodeproj
open Lumisound.xcodeproj   # build from Xcode
```

Set your Apple development team in **Xcode → Signing & Capabilities** before archiving.

### Lua Theme Presets

Lua scripts (theme presets, effects, visualizers, smart-playlist and vault rules) run on the Rust core's sandboxed Lua 5.4 runtime (`rust/core/src/lua.rs`: math/string/table/utf8 only, a `json` module, a 3-second budget per script). No Swift package is involved.

The 10 bundled presets live in `Lumisound/Resources/LuaPresets/*.lua` and are bundled as a folder reference (declared under the `Lumisound` target's `resources:` in `project.yml`) so `LuaThemeEngine` can look each one up by name at runtime. Each preset script assigns a single global `theme` table covering colors, font/panel/artwork/seeker/card styles, Liquid Glass tuning, feature flags, and a couple of Library tab display-logic hooks — see any of the 10 files for the exact shape, or `LuaThemeConfig` in `LuaThemeEngine.swift` for the Swift-side schema they decode into. Users pick a preset from **Settings → Appearance → Lua Theme Presets**.

### CI / GitHub Actions

Push to `main` triggers the **Build iOS IPA** workflow (artifact only).  
Push a tag `ios/v*` (e.g. `ios/v1.3.0`) triggers the **Release iOS IPA** workflow which:
1. Stamps the version into `project.yml`
2. Builds and packages the unsigned IPA
3. Creates a GitHub Release with the IPA attached
4. Updates `altstore-source.json` automatically

---

## Privacy

- No analytics or crash reporting sent to third parties.
- Account data (playlists, settings) stored on the bridge server you connect to.
- Apple Music library access is optional and only used to display your local tracks.
- Streaming uses yt-dlp on the bridge server — no data is sent to Google or SoundCloud directly from the app.

---

## License

MIT — see [LICENSE](../LICENSE).
