<p align="center">
  <img src="ios/Lumisound/Resources/Assets.xcassets/AppIcon.appiconset/Icon-1024.png" width="120" alt="Lumisound icon">
</p>

<h1 align="center">Lumisound</h1>

<p align="center">
  A full-featured, privacy-respecting music player for iOS, watchOS, and tvOS — stream from
  YouTube and SoundCloud, manage a personal cloud library, apply spatial 8D audio and a
  10-band EQ, listen together over SharePlay, and sync everything across devices with a
  free account.
</p>

---

## Repository layout

| Path | What it is |
|---|---|
| [`ios/`](ios) | The Xcode project — one `xcodegen` project, five targets: the iPhone/iPad app, a Home/Lock Screen + StandBy widget, an Apple Watch app + its own complication widget, and a full Apple TV app. Install instructions, build steps, full feature docs |
| [`rust/core/`](rust/core) | **The app engine, in Rust** (UniFFI → Swift module `LumisoundCore`): the audio engine (symphonia decode, gapless/crossfade mixer, EQ, reverb, CoreAudio output), the bridge API client and live socket, the `.lms` lock system and track vault, downloads, on-device analysis (BPM, key, loudness, beat grid, fingerprints, silence, hum-to-search), the library/scan caches and stores, the appearance system, and the Lua scripting runtime. Swift keeps the SwiftUI views and the Apple-only system APIs |
| [`rust/media/`](rust/media) | Media primitives shared by the app and the server: lock format, decoding, analysis DSP, tag writing |
| [`rust/bridge/`](rust/bridge) | Rust (axum + sqlx) server powering search/streaming, account sync, Aria Lumi (AI features), and all server-side features below; host deploy files in [`ios-bridge/`](ios-bridge) |
| [`rust/rpc/`](rust/rpc) + [`discord-rpc/`](discord-rpc) | Optional Rust daemon that mirrors your "now playing" to Discord Rich Presence, plus its installers |

Everything functional is Rust; see [`RUST-PORT.md`](RUST-PORT.md) for what moved where.

See [`ios/README.md`](ios/README.md) for installation (AltStore / Sideloadly), self-hosting the
bridge, and build-from-source instructions.

---

## Features

### Playback & Audio

| Feature | Details |
|---|---|
| **Playback** | Gapless, crossfade, A–B repeat, sleep timer, sleep/wake alarm with graduated volume, variable speed & pitch, auto-radio, track bookmarks |
| **Smart Auto Crossfade** | Beatmatches outgoing/incoming tempos and snaps the fade to a downbeat, reading how the outgoing track actually sounds as it ends rather than a fixed slider |
| **Interface styles** | Liquid Glass, Frosted, Solid, Midnight OLED, Neon, Aurora and Minimal Mono, each in Compact/Regular/Roomy density — synced to your account |
| **Audio FX** | 10-band EQ with presets (+ Auto EQ, which switches presets per track by genre/tempo/live analysis), 23 effects (8D spatial audio, bass boost, tremolo, vibrato, nightcore, vaporwave, karaoke vocal removal…), real-room reverb (on by default, adjustable room/mix) |
| **Per-Track Sound** | Pin EQ/effects/volume overrides to a specific song |
| **ReplayGain & Volume Boost** | Loudness normalisation plus up to 200% volume with a limiter |
| **Now Playing** | 25 selectable visual styles for the album art (vinyl, cassette, aurora, glitch/VHS, and more), plus a built-in editor to design and save your own; full transport controls, Up Next queue, lock-screen & headphone controls, synced lyrics |
| **AI DJ Mode** | Opt-in — Aria Lumi writes a short spoken transition line between tracks, read aloud on-device (no audio ever leaves the device) while volume briefly ducks |
| **Silence Trim** | Opt-in — automatically skips up to 10 seconds of dead air at the start of a local track, analyzed and cached on-device the first time it plays |
| **Long Track Resume Points** | Any local track 20+ minutes long (DJ mixes, audiobook files) automatically remembers your position and resumes there — the same continue-listening treatment podcast episodes already get |
| **Voice Memo Bookmarks** | Attach a short (up to 60s) recorded voice note to any track bookmark — local-only, doesn't travel with the bookmark if it syncs to another device |
| **Practice Mode** | A dedicated tool for learning a track by ear — a visual metronome synced to the track's detected tempo (live-adjusted for playback speed), a sub-100% speed slider with quick presets, and Loop Region controls built on the existing A-B repeat; export the loop region as a standalone .m4a clip to share or use as a ringtone |
| **Focus Sessions** | A Pomodoro-style work/break timer tied to playback — plays a chosen soundtrack through work blocks, pauses for breaks, notifies you at each transition, and tracks completed sessions |
| **Listen Together** | SharePlay session keeps everyone's playback in sync; participants can also suggest tracks into a shared queue and upvote each other's picks, with the top-voted pick playable in one tap. Live emoji reactions float on everyone's screen in real time — purely in-the-moment, nothing saved |
| **Widgets & Live Activity** | Home Screen, Lock Screen, and StandBy widgets plus a Live Activity showing the current track; CarPlay support for browsing and transport controls; Siri/Shortcuts App Intents; a Focus Filter to tie playback behavior to a Focus mode |
| **Companion apps** | A full Apple Watch app (its own library browsing, playback, and widget) and Apple TV app (library, playlists, playback) — both talk to the same bridge account as the phone |

### Library

| Feature | Details |
|---|---|
| **Home dashboard** | The Library tab opens on a customizable dashboard — Quick Access shortcuts, Weekly Mix, Mixes, Recently Added, On Repeat, Genres, Moods, Forgotten Favorites, On This Day, Friends Activity, and more. Reorder or hide any shelf, set a custom greeting, and pick a dashboard-only accent color |
| **Local files** | Import from the Files app, drag-and-drop on iPad, watched folders auto-rescanned on launch |
| **Apple Music library** | Scan and play your existing iTunes/Apple Music library on-device |
| **Folder/album organisation** | Albums derived from directory names; list, 2-col, and 3-col grid layouts |
| **Playlist folders & tags** | File playlists into folders and attach free-form tags to keep things organised |
| **Smart Playlists** | Rule-based playlists (favorite status, play count, duration, genre, and more) that refresh themselves every time you open them |
| **M3U import/export** | Bring in a `.m3u`/`.m3u8` playlist from another app (matched by filename, falling back to title/artist), or export any playlist as one |
| **Downloads manager & Recently Deleted** | See every downloaded track's on-disk size, sort by size or date, delete individually or in bulk; deletions land in a 30-day Recently Deleted safety net first |
| **Recently Deleted Playlists** | The same 30-day undo safety net, for playlists — restore one with its original id intact, or delete it forever right away |
| **Duplicate & corrupt file finders** | Duplicate Finder groups likely-duplicate downloads by matching how they actually sound via audio fingerprinting (AcoustID), not just title text; Corrupt File Finder flags any download that fails to play so you can re-fetch just that one |
| **Library Health** | A single 0-100 scorecard tying together Duplicate Finder, Corrupt File Finder, and two new checks (missing metadata, low bitrate) — tap any category to jump straight to the affected songs |
| **Compare Playlists** | Pick two playlists to see what overlaps and what's unique to each, with a one-tap Save as New Playlist for any of the three resulting lists |
| **Aria Lumi metadata matching** | Built-in, always on — when a local file has more than one possible metadata match, Aria Lumi (Lumisound's own music intelligence) reviews the candidates using titles, artists, cover art, and a sense of your own listening habits to pick the right one instead of a plain "first result" guess, and learns from any corrections you make |

### Podcasts

| Feature | Details |
|---|---|
| **Search & subscriptions** | Discover and subscribe to podcasts; new-episode push notifications; OPML import/export to bring subscriptions in from (or out to) another podcast app |
| **Playback** | Chapter support (Podcasting 2.0 chapters JSON), offline episode downloads, opt-in auto-download of new episodes, a Continue Listening teaser on the Home hub |
| **Trending** | A discovery feed via Apple's public podcast chart, excluding shows you already subscribe to — the first real "what's out there" surface for podcasts, distinct from search which requires already knowing the name |

### Streaming (via the bridge server)

| Feature | Details |
|---|---|
| **Search & stream** | YouTube and SoundCloud search, with playlist/album URL resolution (up to 50 tracks) |
| **Name That Tune** | A Home quick action that listens through the microphone for ~12 seconds and identifies the actual recording playing nearby via audio fingerprinting (AcoustID/MusicBrainz, the same technology behind Shazam) — requires a personal AcoustID key |
| **Spotify link import** | Paste a Spotify track/album/playlist link — the bridge reads public Spotify metadata only (never audio, which Spotify DRM-protects) and matches each track to a playable YouTube result. Requires the server operator to set `SPOTIFY_CLIENT_ID`/`SPOTIFY_CLIENT_SECRET` |
| **Downloads** | Save streamed tracks to your local library with format choice (Opus, MP3, AAC, Best); an opt-in Wi-Fi Only Downloads setting blocks new downloads while on cellular |
| **Background downloads & Pending Imports** | Downloads keep running server-side even if you close the app; a Pending Imports screen (Cloud Services menu) shows what's finished and waiting, which folder it's headed for, and lets you override the folder or import on demand |
| **Personal Cloud Library** | Upload your own files to a private server folder; play and manage from any device |
| **Discover Mix** | A personalised mix seeded from your most-played artists, excluding anything you already have |
| **Trending & Activity** | See what's popular and what other opted-in users are playing right now |
| **Artist Subscriptions** | Follow YouTube/SoundCloud channels — get notified and queue new uploads automatically |

### Account & Sync

| Feature | Details |
|---|---|
| **Free accounts** | Username/password, no email required — sync playlists, favourites, settings, and play history |
| **Push/pull sync** | Background sync on every change and app launch; pull merges rather than overwrites |
| **Backup history** | Automatic pre-sync snapshots you can restore from |
| **Queue sync** | Your Up Next queue is saved server-side and restored on other signed-in devices |
| **Rewind** | A shareable "Wrapped"-style recap card — All Time, This Month, or This Year — with top songs/artists, listening time, and (for Month/Year) distinct artists/tracks, average BPM, and peak listening day |
| **Achievements** | Listening streaks, play-count and listening-time badges, time-of-day badges |
| **Listening Goal** | Set a weekly listening-time target and track real progress against it — forward-looking, unlike Achievements' retrospective badges |
| **Notifications** | In-app inbox for achievement unlocks, subscription uploads, and collaborator activity — delivered as real background push when the server operator configures an APNs key (`APNS_KEY_BASE64`/`APNS_KEY_ID`/`APNS_TEAM_ID`), otherwise surfaced on next foreground/poll |

### Sharing & Social

| Feature | Details |
|---|---|
| **Friends & profiles** | Add friends, accept/decline requests, and view a friend's public profile — banner, avatar, bio, pinned tracks, and live online/now-playing status if they share it. Your own Profile tab shows the same public view with an Edit button, rather than opening straight into editing |
| **Listening Twin** | Finds and names the single other opted-in user whose top artists overlap most with yours — match %, shared artists, one-tap friend request, plus a Twin Mix seeded from their other favorites |
| **Music Match & Blend Mix** | A friends-only "% match" score with shared artists/genres on a friend's profile, plus a Play Blend Mix button for an actual listenable mix of both your top artists — the intentional, chosen-friend counterpart to Listening Twin's auto-matched stranger |
| **Collaborative playlists** | Share a playlist via code/link; invite others as Editor or Viewer, revoke anytime |
| **Mixtape Cards** | Generate a designed cover image for any playlist — artwork collage, name, length, tracklist — to share anywhere via the system share sheet; a purely aesthetic export, not a live invite |
| **Shared with Me** | View, play, or save a local copy of playlists others have shared with you |
| **Scrobbling** | Link Last.fm and/or ListenBrainz to scrobble finished tracks automatically |
| **Discord Webhook** | Post a "Now Playing" message to a Discord channel via incoming webhook |
| **Discord Rich Presence** | Generate a per-user token and register your Discord Application Client ID in-app; the [local Rich Presence daemon](discord-rpc) picks up both automatically and shows "Listening to X by Y" on your Discord profile while Discord is open |

### Extras

| Feature | Details |
|---|---|
| **Needle Drop** | A music-guessing mini-game built from your own library — a short clip plays from a random point in a random track, guess it from 4 choices before it fades out, and build a streak. Fully on-device |
| **Time Capsules** | Seal a set of songs (from Favorites or a playlist) with a note to your future self, locked until a date you choose; a notification lets you know the moment it unlocks. Fully on-device |
| **Constellation** | Maps your library as a scatter of genre or artist "stars" sized by song count — tap one to shuffle-play or browse it. A visual alternative to browsing by list/grid |
| **Listening Heatmap** | A GitHub-style calendar grid of the last year of listening activity — darker days mean more plays |
| **Aria's Daily Pick** | A Home dashboard card with one AI-picked track a day and a short reason from Aria Lumi, seeded from your own top artists — cached server-side so it costs at most one AI call per user per day |
| **Liner Notes** | A short Aria-written note on any album's detail screen — genre, mood, catalog context — cached per album rather than per user, so it costs at most one AI call ever per unique album across the whole server |
| **Gallery Background** | A full-screen animated background behind every screen — either your own photos (with 8 transition styles, blur/opacity, Ken Burns motion) or **Sonic Wallpaper**, a generative alternative with no photos needed: a soft gradient built from the color palettes of your own most-played/favorited tracks' artwork |

### Privacy

- No third-party analytics or crash reporting.
- Account data (playlists, settings, history) lives only on the bridge server you connect to.
- Apple Music access is optional and read-only.
- "Share Listening Activity" (for Trending/Discover) is off by default and shares only titles/artists.
- **Aria Lumi** (Settings → Account → AI Features) — built into the app, always on, no opt-in toggle.
  For local files with more than one possible metadata match, titles/artists/albums/cover art for
  those candidates, plus a lightweight signal from your own play history and favorites (which artists/
  albums you actually listen to and how much, not full listening history), are sent to Google's Gemini API
  to pick the correct match instead of a plain "first result" guess, and she learns from any corrections
  you make. No audio or file contents are ever sent, and she never overrides an already-exact match by
  herself without reviewing the alternatives first.
- **AI DJ Mode** (Settings → Account → AI Features) — off by default. When enabled, only the
  titles/artists of the two tracks either side of a transition are sent to write a spoken
  transition line; the line itself is read aloud entirely on-device (`AVSpeechSynthesizer`), so
  nothing about your voice is ever recorded or sent anywhere.

---

## In-app help

The app includes a full **Help & Feature Guide** (Settings → Help) covering every feature above
in detail, with usage tips for each.

READ IT!!!

---

## License

MIT — see [LICENSE](LICENSE).
