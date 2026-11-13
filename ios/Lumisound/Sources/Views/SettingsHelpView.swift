import SwiftUI

// MARK: - HelpTopic

/// A single help entry — one row in a `SettingsHelpDetailView`.
private struct HelpTopic: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let body: String
}

// MARK: - HelpCategory

/// A top-level entry in the Help & Feature Guide index. Each category opens
/// its own page of `HelpTopic`s, rather than the guide being one long scroll
/// of every topic at once.
private struct HelpCategory: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let topics: [HelpTopic]
}

// MARK: - SettingsHelpView

struct SettingsHelpView: View {

    var body: some View {
        LKPage(title: "Help & Guide", subtitle: "What every Lumisound feature does, and where to find it.", icon: "book.fill", tint: .blue) {
            LKSection {
                ForEach(Self.categories) { category in
                    NavigationLink(destination: SettingsHelpDetailView(category: category)) {
                        Label(category.title, systemImage: category.icon)
                            .foregroundStyle(AppTheme.textPrimary)
                    }
                    .buttonStyle(LKRowLinkStyle())
                }
            } header: {
                sectionHeader("Topics")
            } footer: {
                Text("Pick a category for details on what each feature does and how to use it.")
                    .font(AppTheme.bodyFont(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        // Without an explicit style this defaults to a grouped-card look —
        // see FavoritesView's identical fix.
        .background(GalleryBackgroundView().ignoresSafeArea())
        .navigationTitle("Help & Feature Guide")
        .navigationBarTitleDisplayMode(.large)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AppTheme.bodyFont(size: 11))
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(0.8)
    }

    // MARK: — Category Data

    private static let categories: [HelpCategory] = [
        HelpCategory(icon: "house.fill", title: "Home", topics: [
            HelpTopic(
                icon: "square.grid.2x2.fill",
                title: "The Home Dashboard",
                body: "The Home tab (first tab in Library) is a dashboard of shortcuts and auto-generated shelves rather than a plain file browser: Quick Access shortcuts to your real playlists/folders/favorites, a Weekly Mix, your Mixes (rule-based smart playlists), Recently Added, On Repeat, Recently Played, Genres, Forgotten Favorites, Moods, On This Day throwbacks, Friends Activity, and Similar Listeners. Each shelf only appears once it actually has something to show — an empty library shows a simplified welcome view instead."
            ),
            HelpTopic(
                icon: "waveform.badge.magnifyingglass",
                title: "Name That Tune",
                body: "The Name That Tune quick action on Home listens through the microphone for about 12 seconds and identifies the actual recording playing nearby — precise audio fingerprinting against the AcoustID/MusicBrainz database, the same technology behind Shazam, not a guess from humming. Requires a personal AcoustID key (Settings → Streaming) and being signed in. Distinct from Hum to Search, which matches a hummed melody against your own library instead."
            ),
            HelpTopic(
                icon: "slider.horizontal.3",
                title: "Customize Home",
                body: "Tap the slider icon in the Home tab's toolbar to open Customize Home: drag to reorder any shelf, or toggle one off entirely if you don't want to see it (the Greeting header and Quick Actions row always stay pinned at the top). The same sheet also lets you set a custom greeting message that replaces the automatic \"Good morning/afternoon/evening\" line, and pick a Home-only accent color — separate from your profile's accent — that tints this screen's section headers and greeting text. All three are saved on this device only, not synced to your account."
            ),
        ]),
        HelpCategory(icon: "rectangle.bottomthird.inset.filled", title: "Navigation", topics: [
            HelpTopic(
                icon: "rectangle.bottomthird.inset.filled",
                title: "Navbar Mode: Tabs or Mini Player",
                body: "Settings → Appearance → Navbar Mode switches the oval bar at the bottom of the screen between two looks, without ever changing its size. Tabs is the familiar row of destinations. Mini Player replaces that row with circular artwork, a marquee title, a seeker, and back/play-pause/forward controls whenever a song is loaded, automatically falling back to the tab row when nothing's playing. The same toggle is also in Now Playing's overflow menu (⋯) for quick access, and — fastest of all — you can just swipe up or down anywhere on the navbar itself to flip between the two instantly, no menus required."
            ),
            HelpTopic(
                icon: "eye.slash",
                title: "Hiding Tabs & Tab Bar Style",
                body: "Settings → Appearance → Hidden Tabs lets you turn off any tab you don't use (Library, Playing, Queue, Cloud Services, Friends, Profile) — Settings itself can never be hidden, so you can always get back here to change your mind. A hidden tab's screen is still fully reachable through normal in-app navigation; it just doesn't get a button in the bar. Two more options above that control the Tabs-mode bar's look: Show Tab Labels (icon-only vs. icon+label) and Selection Style — Glass Pill (the original small bubble behind the icon), Underline, or Filled Capsule."
            ),
            HelpTopic(
                icon: "sparkles",
                title: "Lumen vs. Classic Interface",
                body: "Lumisound has two complete interfaces you can switch between any time in Settings → Appearance → Interface: Lumen, a full redesign with its own Home/Search/Library/Now Playing/You screens and a palette that shifts to match whatever's playing; and Classic, the original interface exactly as it's always been. Everything else in this guide works the same under both — Lumen just presents it differently. New installs see a one-time welcome card offering the choice on first launch; switching later never loses any data."
            ),
        ]),
        HelpCategory(icon: "play.circle", title: "Playback", topics: [
            HelpTopic(
                icon: "waveform.path.ecg",
                title: "Crossfade",
                body: "Crossfade smoothly blends the end of one track into the beginning of the next so there is no sudden silence between songs. The duration slider controls how many seconds the overlap lasts — shorter values (1–3 s) give a subtle fade, longer values (6–10 s) produce a DJ-style blend. Crossfade works best with music at similar tempos."
            ),
            HelpTopic(
                icon: "infinity",
                title: "Gapless Playback",
                body: "Gapless playback removes all silence between tracks so they play back-to-back without any pause. This is different from crossfade — the songs do not overlap; they simply butt up against each other seamlessly. It is ideal for live albums, DJ sets, and concept records designed to flow as one continuous piece."
            ),
            HelpTopic(
                icon: "repeat",
                title: "A–B Repeat",
                body: "A–B Repeat lets you loop a precise segment of a track. Tap A to mark the start point and B to mark the end point while a song is playing; the app then loops only that region indefinitely. Tap Clear to remove the markers and resume normal playback. Useful for learning music, transcribing passages, or drilling a specific section."
            ),
            HelpTopic(
                icon: "moon.zzz",
                title: "Sleep Timer",
                body: "The Sleep Timer pauses playback after a set amount of time — useful for falling asleep to music without leaving audio running all night. Choose a preset duration (5 minutes to 2 hours) and tap Start. The remaining time appears as a pill in Now Playing. Tapping the pill opens the timer sheet where you can cancel early. If you grant Health access, the sheet also offers a \"Use suggested\" duration learned from your own actual sleep data (via HealthKit) instead of guessing a fixed preset — it refines the longer you use it."
            ),
            HelpTopic(
                icon: "timer",
                title: "Focus Sessions",
                body: "Now Playing → overflow menu → Focus Session opens a Pomodoro-style work/break timer: pick work and break lengths and a number of rounds, choose a soundtrack (keep whatever's playing, Favorites, or a playlist), and it automatically plays through work blocks and pauses for breaks, notifying you at each transition even if you've left the app. Tracks how many sessions you've completed."
            ),
            HelpTopic(
                icon: "sparkles",
                title: "Auto-Radio",
                body: "Auto-Radio automatically appends new songs to the queue when it is about to run out. When the last track finishes, Lumisound searches YouTube for songs similar to the one you were just listening to and queues up the top results. Toggle it on in the Now Playing screen. Requires an internet connection."
            ),
            HelpTopic(
                icon: "waveform.slash",
                title: "Silence Trim",
                body: "Settings → Audio → Silence Trim automatically skips past dead air at the very start of a local track — up to 10 seconds — a common ripping/mastering artifact. Each track is analyzed on-device the first time it plays and cached, so it's instant after that. Off by default; only applies to local files, not streamed tracks."
            ),
            HelpTopic(
                icon: "speaker.wave.3",
                title: "ReplayGain",
                body: "ReplayGain normalises the perceived loudness across your library so you do not have to keep adjusting the volume when switching between tracks recorded at different levels. The app reads the REPLAYGAIN_TRACK_GAIN and REPLAYGAIN_ALBUM_GAIN metadata tags embedded in your audio files. If a file has no gain tag the track is played at its original volume."
            ),
            HelpTopic(
                icon: "speaker.wave.3.fill",
                title: "Volume Boost",
                body: "The volume slider in Now Playing can go above 100%, up to 200%, for tracks recorded at a low level. A limiter automatically smooths out loud peaks so the boosted output doesn't crackle or distort — you'll see a \"Boost\" label appear once you go past 100%."
            ),
            HelpTopic(
                icon: "pin",
                title: "Per-Track Sound Settings",
                body: "Adjust the EQ, effects, volume, or any other sound setting for the current track, then tap Save in the \"Custom Sound for This Track\" panel in Now Playing to pin those settings to that song specifically. They'll be recalled automatically every time the track plays, without affecting your default settings for everything else. Tap Remove to go back to your defaults for that track."
            ),
            HelpTopic(
                icon: "metronome",
                title: "Smart Auto Crossfade",
                body: "Smart Auto Crossfade (Settings → Audio) is an alternative to manual Crossfade that picks its own transition timing per-track instead of a fixed slider — it beatmatches the outgoing and incoming songs' tempos and snaps the fade to land on a downbeat, and reads how the outgoing track actually sounds right as it ends (a live audio analysis, not just a genre/tempo guess): a quiet fade-out gets a longer, gentler blend, while a track still at full energy gets a tighter one so two loud passages don't smear together. Turning it on automatically turns manual Crossfade off, since only one transition strategy can be active."
            ),
            HelpTopic(
                icon: "metronome",
                title: "Practice Mode",
                body: "Now Playing → overflow menu → Practice Mode opens a dedicated tool for learning a track by ear: a visual metronome pulse synced to the track's detected tempo (adjusted live for playback speed, so it always matches what you're actually hearing), a speed slider capped at 100% with quick 50/75/90% presets, and Loop Region controls (the same A-B repeat markers available elsewhere) to repeat just the section you're working on. Built from existing playback controls, not a separate audio engine. Once a loop is set on a local (downloaded/imported) track, an Export Clip button saves that exact region as a standalone .m4a file you can share, AirDrop, or bring into GarageBand/Finder to set as a ringtone."
            ),
            HelpTopic(
                icon: "waveform.badge.minus",
                title: "Separate Vocals / Instrumental",
                body: "Now Playing's overflow menu (⋯) → Separate Vocals / Instrumental runs real AI stem separation (Demucs, processed server-side) on the current track, splitting it into standalone vocal and instrumental versions you can play or save separately — not an EQ trick, an actual source-separation model. Takes a little while to process; works best on studio-produced tracks."
            ),
            HelpTopic(
                icon: "video.badge.waveform",
                title: "Share as Video (Lyric Clips)",
                body: "Now Playing's overflow menu (⋯) → Share as Video turns a track (with synced lyrics) into a short shareable video clip — pick the section, and it renders the lyrics animating over the artwork as a video file ready for Stories or anywhere else that wants a video rather than a plain audio share."
            ),
            HelpTopic(
                icon: "gobackward",
                title: "Long Track Resume Points",
                body: "Any local track 20 minutes or longer (a DJ mix, an audiobook file, a long mixtape) automatically remembers where you left off — no setup needed. Switch away partway through and come back later, even after closing the app, and it picks up right where you stopped, the same way podcast episodes already do. Doesn't apply to shorter tracks."
            ),
            HelpTopic(
                icon: "bookmark",
                title: "Track Bookmarks",
                body: "Bookmark specific timestamps within a long track (a DJ mix, podcast, or audiobook-style file) to jump straight back to them later — useful for marking \"the drop\" or a chapter start. Bookmarks are entirely on-device and don't require an account. Tap the mic icon on a bookmark to attach a short voice memo to it (up to 60 seconds) — handy for narrating why a moment matters instead of just typing a label. Voice memos are local-only: they stay on this device even if the bookmark itself syncs to your account."
            ),
            HelpTopic(
                icon: "gobackward.15",
                title: "Instant Replay",
                body: "Now Playing → overflow menu (⋯) → Replay Last 15s jumps back 15 seconds on the spot — no sheet, nothing saved, just an instant \"wait, what was that\" rewind for whatever just played."
            ),
            HelpTopic(
                icon: "waveform.and.magnifyingglass",
                title: "Shake to Skip & Cover to Pause",
                body: "Two independent gestures, both off by default, toggled separately from Now Playing's overflow menu (⋯): Shake to Skip advances to the next track when you physically shake the phone; Cover to Pause pauses when you cover the sensor near the earpiece/camera (held briefly, so a casual grip doesn't trigger it by accident). Turn on just one, both, or neither."
            ),
            HelpTopic(
                icon: "rectangle.stack.badge.plus",
                title: "Sync My Devices",
                body: "Now Playing's overflow menu (⋯) → Sync My Devices broadcasts this device's current playback to your other signed-in devices, so a second phone or iPad can follow along in real time without starting its own separate playback. Any device willing to auto-pick-up a session has its own separate toggle elsewhere, since hosting and auto-joining are different decisions."
            ),
            HelpTopic(
                icon: "pin",
                title: "Playlist-Level Sound Override",
                body: "A playlist can have its own saved sound settings, the same way an individual track can (see Per-Track Sound Settings above) — open a playlist while it's playing and save a \"Custom Sound for This Playlist\" panel the same way. Priority order: a track's own pin always wins first; otherwise, if it's playing as part of a playlist with a saved override, that applies; otherwise your regular default settings."
            ),
        ]),
        HelpCategory(icon: "slider.vertical.3", title: "Audio Effects", topics: [
            HelpTopic(
                icon: "slider.vertical.3",
                title: "EQ Presets",
                body: "The 10-band equalizer ships with several presets tuned for different listening styles. Flat leaves all bands at 0 dB (no colouration). Bass Boost emphasises the low end. Treble Boost brightens the high end. Vocal/Podcast scoops the sub-bass and boosts the mid-range where speech sits. Custom lets you drag each band freely and saves your settings automatically."
            ),
            HelpTopic(
                icon: "waveform.path",
                title: "Bass Boost",
                body: "Bass Boost is a quick single-toggle alternative to the full EQ that amplifies the 32 Hz and 64 Hz frequency bands. The Boost Gain slider lets you dial in how much extra punch you want, from a gentle 2 dB lift to a heavy 15 dB boost. The effect is separate from the EQ bands so you can combine both if needed."
            ),
            HelpTopic(
                icon: "circle.grid.3x3",
                title: "8D Audio",
                body: "8D Audio applies a rotating panning effect that makes the sound appear to move around your head when listening on headphones. The audio sweeps left and right in a slow cycle, giving the impression of three-dimensional space. It is an artistic effect and works best with headphones; on speakers the effect is minimal."
            ),
            HelpTopic(
                icon: "waveform",
                title: "Tremolo",
                body: "Tremolo modulates the volume of the audio at a regular rate, creating a rhythmic wavering effect familiar from vintage guitar amplifiers and 1960s recordings. You can adjust the rate (how fast the volume pulses) and depth (how extreme the dip is). Subtle settings add warmth; high-depth settings at fast rates produce a choppy, effect-heavy sound."
            ),
            HelpTopic(
                icon: "tuningfork",
                title: "Vibrato",
                body: "Vibrato modulates the pitch of the audio at a regular rate, producing the characteristic wobble heard in classical violin technique and vintage synthesizers. Rate controls the speed of the pitch oscillation and depth controls how wide the pitch swings. Like tremolo it is an artistic effect that can range from barely perceptible to exaggerated."
            ),
            HelpTopic(
                icon: "hare",
                title: "Pitch & Speed",
                body: "The Speed slider changes how fast the audio plays, from 0.5× (half-speed) to 2.0× (double-speed), without affecting pitch. The Pitch slider shifts the pitch up or down by up to 12 semitones independently of speed. Tap the pencil icon next to either value to type in an exact number. These controls are also accessible in the Now Playing screen under Playback Controls."
            ),
            HelpTopic(
                icon: "water.waves",
                title: "Reverb",
                body: "Reverb (on by default) simulates the sound of a physical room, from a small booth up to a cathedral — pick a room size and adjust the wet/dry mix slider to control how present the effect is, from 0% (no reverb, dry signal only) to 100% (fully wet). The mix is a true crossfade between the dry and processed signal, so every point on the slider is audibly different — not just the top end of the range."
            ),
            HelpTopic(
                icon: "wand.and.stars",
                title: "Auto EQ",
                body: "Auto EQ (Settings → Audio, requires the Equalizer to be on) automatically switches the active EQ preset to match each track — first by its genre tag, falling back to its analyzed tempo when untagged. A couple of seconds into each track it also fine-tunes the bass/treble balance based on a live analysis of how the track actually sounds, so a bass-light mix gets a touch more low end and an already bass-heavy one doesn't get over-boosted by a generic preset. The manual preset picker is hidden while Auto EQ is on, since the preset changes automatically per track. A small \"why this pick\" line in the Equalizer screen explains the actual reason behind the current preset — genre, tempo, or a direct measurement of the mix — instead of leaving it unexplained."
            ),
        ]),
        HelpCategory(icon: "music.note.list", title: "Library", topics: [
            HelpTopic(
                icon: "folder.badge.plus",
                title: "Importing Files",
                body: "You can import audio files (MP3, AAC, FLAC, ALAC, OGG, OPUS, WAV, and more) from the Files app using the Add Music button in the Library tab. Files are copied into Lumisound's private Documents folder so they remain available even if the original location changes. Drag and drop from other apps on iPad is also supported."
            ),
            HelpTopic(
                icon: "folder.badge.gearshape",
                title: "Watched Folders",
                body: "Watched Folders let you point Lumisound at a folder inside the Files app (for example an iCloud Drive folder or a USB drive via the Files app) and have it automatically include any audio files found there in your library. The folder is rescanned every time the app launches. Tap the folder icon on the Library screen to add or remove watched folders."
            ),
            HelpTopic(
                icon: "square.grid.2x2",
                title: "Column & Grid Layouts",
                body: "The Songs tab offers a list view (1 column) and grid views (2 or 3 columns). Tap the layout icons in the top-right corner to switch between them. The Albums tab similarly supports 1, 2, or 3 column grids. Your layout preference is saved per-section and restored the next time you open the app."
            ),
            HelpTopic(
                icon: "arrow.up.arrow.down",
                title: "Sort Options",
                body: "Songs in the library are sorted alphabetically by title by default. Use the search bar to filter the visible list in real time — results update after a short debounce delay so the app does not re-render on every keystroke. Artists and albums are sorted alphabetically. Playlists appear in the order you created them."
            ),
            HelpTopic(
                icon: "arrow.clockwise",
                title: "Refresh",
                body: "The refresh button in the top-right of the Library tab re-scans your Documents folder and watched folders for new or changed files. If you're signed in, it also pulls your latest favourites, playlists, and settings from the server — useful after making changes on another device."
            ),
            HelpTopic(
                icon: "wand.and.stars",
                title: "Automatic Metadata Lookup",
                body: "Whenever new tracks are scanned in, Lumisound reads the title, artist, album, genre, and year embedded in the file, and fills in anything still missing using online lookups (iTunes, MusicBrainz, and Deezer). Lumisound also periodically re-checks any imported track that's still missing artist, album, genre, or year — for example after deleting and reinstalling the app and copying your music back from a backup folder — so those tracks fill in automatically the next time the app is open, without needing a manual rescan."
            ),
            HelpTopic(
                icon: "wand.and.stars",
                title: "Aria Lumi",
                body: "When a metadata lookup for a local file turns up more than one possible match, Aria Lumi — Lumisound's built-in music intelligence — reviews the candidates for you: comparing titles and artists, looking at each candidate's cover art, and weighing in a lightweight sense of what you actually listen to, rather than just grabbing the first result. She's always on, with nothing to turn on or set up, and she learns from it any time you manually correct a track she got wrong. No audio or file contents are ever sent — only text metadata and cover art for the specific candidates being compared."
            ),
            HelpTopic(
                icon: "text.quote",
                title: "Liner Notes",
                body: "Open any album to see a short Aria-written note about it, when she recognizes it — genre, mood, where it sits in the artist's catalog. Shared across every listener rather than generated per person, so most albums load instantly once anyone has viewed them; some albums show nothing if she's not confident enough to say anything specific."
            ),
            HelpTopic(
                icon: "sparkle",
                title: "Aria's Daily Pick",
                body: "A Home dashboard card showing one track Aria picked for you today, with a short one-line reason — seeded from your own top artists and refreshed once every calendar day. Tap it to play. Requires being signed in and some recent listening history."
            ),
            HelpTopic(
                icon: "internaldrive",
                title: "Downloads Manager",
                body: "Settings → Storage & Cache → Downloaded Music opens a dedicated list of every downloaded/imported track with its on-disk size, sortable by size or date. Swipe a track to delete it, or tap Select to remove several at once — useful for finding and clearing out the largest files when you're low on storage."
            ),
            HelpTopic(
                icon: "icloud.and.arrow.down",
                title: "Background Downloads",
                body: "Once a download starts, the actual conversion happens on the server — it keeps running even if you close the app or lose signal partway through. When it finishes, Lumisound is notified and quietly fetches the finished track into your library on its own, whether that happens seconds later or the next time you open the app. If a download seems to have vanished, it hasn't — just reopen the app and it'll be picked up automatically."
            ),
            HelpTopic(
                icon: "tray.and.arrow.down",
                title: "Pending Imports",
                body: "Cloud Services → menu (top-right) → Pending Imports shows exactly what Background Downloads is doing behind the scenes: any finished download still waiting to be pulled into your library, with the folder it's headed for (a tracked playlist's own folder, or Imported Music by default) — pick a different folder before it lands if you want, or tap Import Now to pull a track in immediately instead of waiting. A Recently Imported feed below it shows what just came in this session and where it went, so background imports aren't a black box."
            ),
            HelpTopic(
                icon: "trash.slash",
                title: "Recently Deleted",
                body: "Deleting a downloaded track (from the Downloads Manager or the general Library view) doesn't remove it immediately — it moves to Recently Deleted (accessible from the Downloads Manager) for 30 days, where you can restore it or delete it permanently right away. This is a safety net for an accidental bulk delete; after 30 days it's purged automatically."
            ),
            HelpTopic(
                icon: "trash",
                title: "Recently Deleted Playlists",
                body: "Settings → Library → Recently Deleted Playlists is the same 30-day safety net as Recently Deleted, for playlists instead of downloaded tracks: deleting a playlist doesn't remove it for good right away. Swipe right on an entry to restore it (same id, so shortcuts and folders pointing at it still work), or swipe left to delete it forever immediately."
            ),
            HelpTopic(
                icon: "rectangle.2.swap",
                title: "Compare Playlists",
                body: "Settings → Library → Compare Playlists picks two playlists and shows what's in both, and what's unique to each, with a Save as New Playlist button for any of the three resulting lists — a quick way to merge two playlists, split off just the overlap, or find what one playlist has that another doesn't."
            ),
            HelpTopic(
                icon: "heart.text.square",
                title: "Library Health",
                body: "Settings → Library → Library Health is a single scorecard tying together Duplicate Finder, Corrupt File Finder, and two new checks (missing metadata, low bitrate under 128 kbps) — a 0-100 score plus a tappable count for each category, so you don't have to remember to open each tool separately. Tap any category to see (and jump to) the affected songs."
            ),
            HelpTopic(
                icon: "doc.on.doc",
                title: "Duplicate Finder",
                body: "Settings → Library → Duplicate Finder scans your downloaded tracks for likely duplicates — first by an exact shared source (the same track downloaded more than once), then, for everything else, by comparing how tracks of a similar length actually sound throughout the track (not just a same-title guess), which catches a duplicate that was re-titled or re-tagged differently across sources. Review each group and delete the copy you don't want, or use Delete All Duplicates to automatically keep the longest/most complete copy in every group at once."
            ),
            HelpTopic(
                icon: "exclamationmark.triangle",
                title: "Corrupt File Finder",
                body: "Settings → Library → Corrupt File Finder checks every downloaded track for playability — catching a truncated or failed download before you hit it mid-playback — and lists anything that fails, so you can delete and re-download just those instead of guessing which file is the problem."
            ),
            HelpTopic(
                icon: "square.and.arrow.down",
                title: "M3U Playlist Import",
                body: "Playlists → the + menu → Import M3U File lets you bring in a .m3u/.m3u8 playlist exported from another app or device. Tracks are matched to your library by filename first, then by title/artist from the playlist's metadata — after importing, you'll see how many of the file's tracks were actually found and added. Any playlist here can also be exported back out as M3U from its own detail screen."
            ),
            HelpTopic(
                icon: "sparkles.tv",
                title: "Smart Playlists",
                body: "Playlists → Smart Playlists are rule-based playlists that update themselves automatically — e.g. \"Most Played\", \"Recently Added\", or a custom combination of rules (favorite status, play count, duration, genre, and more). Create your own with any combination of rules and a sort order; the results refresh every time you open it, no manual maintenance needed."
            ),
            HelpTopic(
                icon: "arrow.triangle.2.circlepath.circle",
                title: "Tracked Playlists (Auto-Download)",
                body: "Paste a YouTube or SoundCloud playlist URL into Tracked Playlists and turn on Auto-Download to have Lumisound periodically check it for new tracks and download them straight into your library in the background, with no need to keep re-checking manually. Each tracked playlist can optionally have its own destination subfolder."
            ),
        ]),
        HelpCategory(icon: "photo.on.rectangle", title: "Background Gallery", topics: [
            HelpTopic(
                icon: "sparkle",
                title: "Sonic Wallpaper",
                body: "Settings → Appearance → Gallery Background → Background Source lets you pick Sonic Wallpaper instead of Photos — a generative background with no photos to add, built entirely from the color palettes of your own most-played and favorited tracks' artwork, slowly cycling between them. Fully automatic and on-device; nothing to configure, and the photo settings on this screen are ignored while it's selected."
            ),
            HelpTopic(
                icon: "photo.on.rectangle",
                title: "How It Works",
                body: "The Gallery Background renders a full-screen image behind all app screens, giving Lumisound its distinctive look. You can add any photos from your Camera Roll or Files app in Settings → Appearance → Gallery Background. When multiple images are added the gallery shuffles through them at a configurable interval. If no images are added the app falls back to its default colour gradient."
            ),
            HelpTopic(
                icon: "sparkle",
                title: "Animation Types",
                body: "Pick how the gallery transitions between images in Settings → Appearance → Gallery Background: Fade cross-fades smoothly; Slide Left and Slide Up pan the next image in from the side or bottom; Zoom In and Zoom Out scale the incoming image while it fades in; Flip rotates between images with a 3D-style effect; Blur In brings the next image into focus; and Cut switches instantly with no animation. Choose a calmer style like Fade or Cut if you prefer a less distracting background."
            ),
            HelpTopic(
                icon: "slider.horizontal.3",
                title: "Blur & Opacity Controls",
                body: "A blur slider softens the background image so it does not compete with text and controls in the foreground. A separate opacity slider lets you fade the image towards the app's base colour. Combining a moderate blur (around 20–40) with a slight opacity reduction (around 0.3–0.5) gives a frosted-glass effect that looks good across many photos."
            ),
            HelpTopic(
                icon: "timer",
                title: "Shuffle Interval",
                body: "When multiple gallery images are loaded, the interval picker controls how long each image is displayed before transitioning to the next one, from every 5 seconds up to every 5 minutes. A shorter interval creates a livelier animated backdrop; a longer interval keeps the background stable so it is less distracting during focused listening sessions."
            ),
            HelpTopic(
                icon: "icloud",
                title: "Synced Per Account",
                body: "Whether the gallery is on or off, the animation style, blur, opacity, and shuffle interval are all saved to your account along with your favourites and playlists. Signing in on another device, or signing into a different account on this device, applies your saved background settings immediately. Your gallery images themselves are also backed up automatically while signed in (see Account → After Reinstall)."
            ),
        ]),
        HelpCategory(icon: "magnifyingglass", title: "Streaming", topics: [
            HelpTopic(
                icon: "magnifyingglass",
                title: "YouTube & SoundCloud Search",
                body: "The Cloud Services tab lets you search YouTube and SoundCloud by title, artist, or paste a full playlist URL. Search results show thumbnail, title, artist, and duration. Tap the play button to stream a track immediately or the download button to save it to your local library. Pasting a YouTube playlist URL fetches the full track list so you can download the entire playlist at once."
            ),
            HelpTopic(
                icon: "waveform",
                title: "Audio Format Preference",
                body: "The Audio Format picker in Settings → Streaming controls which container is requested when streaming or downloading: Opus (best quality per kilobyte, default), MP3 (maximum compatibility), AAC, or Best Available. Opus is recommended for most networks. Use MP3 if you have trouble playing a downloaded track."
            ),
            HelpTopic(
                icon: "wifi",
                title: "Wi-Fi Only Downloads",
                body: "Settings → Streaming → Wi-Fi Only Downloads blocks new downloads (streamed track downloads, background job pickups, tracked-playlist auto-downloads) whenever the device is on cellular with no Wi-Fi available, so you don't burn cellular data without meaning to. Off by default. Streaming playback itself is never affected — only saving a track to your library is."
            ),
        ]),
        HelpCategory(icon: "person.crop.circle", title: "Account", topics: [
            HelpTopic(
                icon: "icloud",
                title: "What Gets Synced",
                body: "Your Lumisound account syncs your favourites list, playlists (names, track order, and membership), audio settings (EQ, speed, pitch, crossfade, etc. — including any per-track overrides), and your accent colour to the server. This lets you restore everything after reinstalling the app or switching to a new device. The actual audio files are not uploaded — only the metadata and preferences."
            ),
            HelpTopic(
                icon: "arrow.up.to.cloud",
                title: "Push Sync",
                body: "A push sync writes your current favourites, playlists, and audio settings up to the server. Pushes happen automatically in the background a few seconds after any change so you normally do not need to trigger them manually. The Account screen shows the last sync time and provides a manual Push button if you want to force an immediate upload."
            ),
            HelpTopic(
                icon: "arrow.down.from.cloud",
                title: "Pull Sync",
                body: "A pull sync downloads your saved state from the server and merges it into what's already on the device — favourites and playlists missing locally are added, but nothing local is ever removed or overwritten by an older server copy, so the two sides simply converge. Pull happens automatically the moment you sign in or create an account, and again on every app launch while you are signed in — so switching accounts on the same device immediately loads that account's library state, badges, and Appearance settings. You can also trigger a manual pull from the Account screen, or from the Library tab's refresh button."
            ),
            HelpTopic(
                icon: "arrow.counterclockwise",
                title: "After Reinstall",
                body: "After reinstalling Lumisound, sign in with the same account and the app will automatically pull your favourites, playlists, and settings from the server. Your local audio files will not be restored automatically — you will need to re-import transferred files, or restore anything you previously uploaded via Cloud Backup. Any streaming downloads that were saved to the app's Documents folder will also be gone and need to be re-downloaded."
            ),
            HelpTopic(
                icon: "clock.arrow.circlepath",
                title: "Backup History",
                body: "Every time your data syncs to the server, the server automatically saves a snapshot of your favourites, playlists, and settings beforehand. If something ever goes wrong with a sync, open Account → Backup History to see recent snapshots and restore one — your current state is backed up first, so a restore can always be undone."
            ),
            HelpTopic(
                icon: "icloud.and.arrow.up",
                title: "Cloud Backup (Uploaded Tracks)",
                body: "Library → Cloud Backup uploads your locally-imported tracks to your account's cloud storage so they survive a reinstall — open Cloud Backup after signing back in to restore them. Use the trash icon in the Uploaded Tracks header to delete everything you've previously uploaded; you'll be asked to confirm, and the count of tracks to be removed is shown in the confirmation. This only removes the cloud copies — your local files are untouched."
            ),
            HelpTopic(
                icon: "ladybug",
                title: "Report a Bug",
                body: "Account → Report a Bug lets you describe an issue, pick a category, and optionally leave a contact email. Your device model, iOS version, and the app version are filled in automatically so the developer can reproduce issues faster — you don't need to look these up yourself. Recent log entries are attached automatically to help with diagnosis. Tap Send to submit; you'll see a confirmation once it's received."
            ),
            HelpTopic(
                icon: "sparkles",
                title: "Discover & Listening Activity",
                body: "Account → Discover shows a Trending list of popular tracks and an Activity feed of what other users are listening to right now. To appear in either, turn on \"Share Listening Activity\" in your Account settings — this shares only song titles and artists from your play history, never file contents, URLs, or anything else. The toggle is off by default."
            ),
            HelpTopic(
                icon: "bell",
                title: "Notifications",
                body: "Account → Notifications is your inbox for server-generated updates: new achievement badges, new uploads from artists you follow, activity on playlists you collaborate on, and storage-quota warnings. A badge on the Account tab and the Notifications row shows your unread count. Tap a notification to mark it read; pull to refresh for the latest. When the app has notification permission, these also arrive as real background push notifications — not just when you happen to have the app open."
            ),
            HelpTopic(
                icon: "key.viewfinder",
                title: "Discord Rich Presence",
                body: "Account → Discord Rich Presence sets up the companion Discord Rich Presence daemon — a small script you run on your own computer that shows \"Listening to <song> by <artist>\" on your Discord profile while Discord is open. Now just two steps: verify your Discord account, then flip Enable Rich Presence — a setup token generates itself automatically and Lumisound's own shared Discord Application is used, so there's no Developer Application to create or Client ID to look up. Copy the token, run \"./install.sh <token>\" from the discord-rpc folder on the computer where Discord is open, and you're done — the token can be revoked any time from Account → Active Sessions (\"Discord RPC Bridge\"). Want your own branding instead of Lumisound's? An Advanced section still lets you register a personal Discord Application, exactly like before. The daemon clears your presence automatically when playback is paused or idle."
            ),
            HelpTopic(
                icon: "message",
                title: "Discord Webhook (Now Playing posts)",
                body: "Account → \"Now Playing Webhook\" is separate from Rich Presence: it posts a one-time message to a Discord channel via an incoming webhook whenever you start a new track, so a server can have a shared \"now playing\" feed. Create an incoming webhook in your Discord server under Channel Settings → Integrations → Webhooks, paste the URL in, and toggle it on or off at any time."
            ),
            HelpTopic(
                icon: "ear",
                title: "Hearing Health",
                body: "Account → Hearing Health correlates your headphone audio-exposure data from Apple Health with how often and how much you've used Volume Boost, so you can see whether boosting volume is actually pushing your real listening levels higher over time rather than just assuming. Requires Health access; nothing here is sent anywhere — it's read and shown entirely on-device."
            ),
        ]),
        HelpCategory(icon: "person.2.wave.2.fill", title: "Friends & Profile", topics: [
            HelpTopic(
                icon: "person.2.fill",
                title: "Friends",
                body: "The Friends tab lists your current friends and any pending requests — accept or decline an incoming request, cancel one you sent, or remove/block an existing friend from their profile. Tap a friend to see their public profile, including whether they're online and what they're listening to right now, if they've chosen to share it."
            ),
            HelpTopic(
                icon: "person.crop.circle",
                title: "Your Profile",
                body: "The Profile tab shows your profile exactly as friends see it — banner, avatar, bio, pronouns, a status emoji + short status text, pinned tracks, and what you're currently listening to. Tap Edit Profile to change any of that: avatar and banner images (including animated GIFs), accent colors, up to 5 pinned favorite tracks, and whether your \"now playing\" status is shared with friends at all."
            ),
            HelpTopic(
                icon: "sparkles",
                title: "Avatar Frame, Decoration & Profile Effect",
                body: "Edit Profile has three purely-animated avatar/banner customizations, stackable together: Avatar Frame draws a ring/glow/dashed/pulse/gradient/double/beads/spin/orbit/halo/arc border around your avatar itself; Avatar Decoration overlays a small looping animation on top of it (Sparkles, Fireflies, Petals, Snowfall, Embers); and Profile Effect plays a looping animation across your whole banner (Blast Off, Aurora, Shooting Stars, Confetti, Rain). All three blend your own chosen Main/Sub accent colors, so they always match the rest of your profile rather than using a fixed palette. Card Style (also in Edit Profile) lets you pick Sharp, Soft, or Round corners for every card on the profile screen, and your Bio supports light Markdown — bold, italic, and links."
            ),
            HelpTopic(
                icon: "bubble.left.and.bubble.right.fill",
                title: "Guestbook, Visitors & Badges",
                body: "A visitor to your profile can leave a short Guestbook message (visible to anyone, like an old-school profile wall) — toggle \"Allow Guestbook Messages\" off in Edit Profile if you'd rather not have that. Edit Profile also has show/hide toggles for your Visitor Count + recent-visitors list and for a Listening Stats card (current streak, badges earned from Achievements, top genres/artists) — each is opt-in since it's more about you showing up than anyone tracking you."
            ),
            HelpTopic(
                icon: "waveform.path.ecg",
                title: "Music Match & Blend Mix",
                body: "A friend's profile shows a Music Match card — a percentage score plus your shared artists/genres, computed from real listening history (friends only). Tap Play Blend Mix underneath it for an actual mix blending both your top artists — the listenable version of that match, not just a number. Distinct from Listening Twin (Account → Library), which auto-matches an anonymous best-fit stranger rather than a friend you already picked."
            ),
            HelpTopic(
                icon: "dot.radiowaves.left.and.right",
                title: "Online Status & Presence",
                body: "While the app is open, Lumisound reports you as online (and what you're playing, if sharing is on) to friends viewing your profile. This updates automatically in the background and clears itself shortly after you close the app or the app goes idle — there's nothing to manually turn on or off beyond the now-playing sharing toggle in Edit Profile."
            ),
        ]),
        HelpCategory(icon: "person.2.fill", title: "Playlists & Sharing", topics: [
            HelpTopic(
                icon: "folder",
                title: "Playlist Folders & Tags",
                body: "Open a playlist and tap the folder icon to file it into a folder (existing or new, just type a name) and attach free-form tags. The Playlists tab groups playlists by folder automatically — playlists without a folder appear at the top. Tags are shown on the playlist detail screen and can be used to keep related playlists organised, e.g. by mood or project."
            ),
            HelpTopic(
                icon: "person.2.badge.gearshape",
                title: "Collaborative Playlists",
                body: "From a playlist, tap Share to generate a share code or link and invite other Lumisound users as Editors (can add/remove songs) or Viewers (read-only). Anyone with the code can open Collaborative Playlists → Enter Share Code to import it. You can revoke a share link at any time, which immediately cuts off access for everyone using it."
            ),
            HelpTopic(
                icon: "photo.artframe",
                title: "Mixtape Card",
                body: "Open a playlist → the folder icon in the toolbar → Mixtape Card generates a designed cover image — artwork collage, name, length, and tracklist — that you can share anywhere via the system share sheet. Purely a picture: unlike Collaborative Playlists' share code, there's no live data or invite behind it, just something nice to post."
            ),
            HelpTopic(
                icon: "tray.and.arrow.down",
                title: "Shared with Me",
                body: "Playlists → Shared with Me lists every playlist another user has added you to as a collaborator, along with your role (Editor/Viewer) and the owner's username. Tap one to view its tracks, play them all, or save a local copy into your own library. Updates from the owner or other collaborators appear automatically the next time you open it."
            ),
            HelpTopic(
                icon: "arrow.triangle.2.circlepath",
                title: "Queue Sync",
                body: "While signed in, your \"Up Next\" queue is saved to the server in the background as it changes, and restored automatically when you open the app on another signed-in device — so you can pick up the same playback queue on your phone and iPad. Only track identifiers and titles are stored, not audio."
            ),
            HelpTopic(
                icon: "shareplay",
                title: "Listen Together Group Queue",
                body: "Once a Listen Together (SharePlay) session is active, the Queue screen shows a Listen Together section. Swipe left on any track and tap Suggest to add it to a shared list everyone in the session can see and upvote. Tap Play Top Voted Next to insert whichever suggestion has the most votes right after the current track. Suggestions and votes only exist for the lifetime of the session — nothing is saved to your account."
            ),
            HelpTopic(
                icon: "face.smiling",
                title: "Listen Together Reactions",
                body: "During a Listen Together session, a row of emoji appears on Now Playing — tap one and it floats up on every participant's screen in real time. Purely in-the-moment: reactions aren't saved anywhere, and a device that joins mid-session won't see ones sent before it arrived."
            ),
        ]),
        HelpCategory(icon: "sparkles", title: "Achievements & Discovery", topics: [
            HelpTopic(
                icon: "target",
                title: "Listening Goal",
                body: "Account → Listening Goal lets you set a weekly listening-time target and tracks real progress against it (last 7 days of actual listen time), with a one-time toast the first time you hit it each week. Forward-looking, unlike Achievements below — a target you set for yourself, not a badge for something you already did. The target itself is saved on this device only."
            ),
            HelpTopic(
                icon: "trophy",
                title: "Achievements & Streaks",
                body: "Account → Achievements tracks your listening streaks (consecutive days with at least one play), total plays, and total listening time, and unlocks badges as you hit milestones for play counts, hours listened, and streak lengths — plus a few special badges like Night Owl and Early Bird for listening at certain times of day. Badges are computed entirely server-side from your play history; there's nothing to configure."
            ),
            HelpTopic(
                icon: "mic.square",
                title: "Trending Podcasts",
                body: "Podcasts → the + button → Trending shows what's currently popular via Apple's public podcast chart, automatically excluding shows you're already subscribed to. Tap one to subscribe immediately — the first real discovery surface for podcasts, since Search requires already knowing what you're looking for."
            ),
            HelpTopic(
                icon: "wand.and.stars",
                title: "Discover Mix",
                body: "Account → Discover → Discover Mix is a personalised list of tracks seeded from the artists you listen to most, automatically excluding anything already in your library or favourites. Tap Play All to queue the whole mix, or play/queue individual tracks. It refreshes as your listening history grows. Tap a track for a short \"why this pick\" explanation of what about your listening got it included, instead of the mix being a black box."
            ),
            HelpTopic(
                icon: "person.2.wave.2",
                title: "Listening Twin",
                body: "Account → Discover → Listening Twin finds and names the single other opted-in user whose top artists overlap most with yours — a match percentage, the artists you share, and a one-tap Add as Friend, plus a Twin Mix seeded from their other favorite artists. Distinct from Similar Listeners on the Home dashboard, which recommends tracks from an anonymous group rather than naming one specific person. Requires \"Share Listening Activity\" to be on (Account settings) and some listening history to compare."
            ),
            HelpTopic(
                icon: "person.crop.circle.badge.plus",
                title: "Artist Subscriptions",
                body: "Account → Subscriptions lets you follow a YouTube or SoundCloud channel/playlist URL by pasting it in and tapping Subscribe. Lumisound checks followed channels for new uploads in the background on a schedule iOS controls (so timing varies — it's not instant), plus any time you tap \"Check Now\". When new tracks appear you get a notification and can play or queue them straight from the Subscriptions screen."
            ),
            HelpTopic(
                icon: "music.note.list",
                title: "Scrobbling (Last.fm / ListenBrainz)",
                body: "Account → Scrobbling links your Last.fm and/or ListenBrainz account so finished tracks are submitted automatically. For Last.fm, tap \"Open Last.fm to Authorize\" to approve access in Safari, then return to the app to complete the link. For ListenBrainz, paste your user token from your ListenBrainz profile settings. Use the top toggle to pause scrobbling without unlinking either service."
            ),
            HelpTopic(
                icon: "clock.arrow.circlepath",
                title: "On This Day",
                body: "Discover → On This Day surfaces tracks you played on today's date in a previous year, grouped by how long ago — a quick throwback to what you were listening to a year (or more) back. It's built from your own play history, so it fills in naturally the longer you use Lumisound."
            ),
            HelpTopic(
                icon: "person.text.rectangle",
                title: "Artist Bio",
                body: "Open any artist from your library to see an \"About\" panel with a short biography, active years, and genre tags pulled from public sources (Wikipedia and MusicBrainz) — no setup needed. Tap \"Read More\" to expand a longer excerpt, or \"Wikipedia\" to open the full article."
            ),
            HelpTopic(
                icon: "mic.fill",
                title: "AI DJ Mode",
                body: "Account → AI Features → AI DJ Mode. When on, Aria briefly ducks the volume and speaks a short transition line as each new track starts, like a real radio DJ handing off between songs, using on-device text-to-speech — nothing about your voice is recorded or sent anywhere. Only the two track titles/artists involved in a transition are sent to write that line. Off by default; requires being signed in. Once on, a Voice picker (any installed system voice — download more under Settings app → Accessibility → Spoken Content → Voices) and a Pitch slider appear underneath, so you can shape how she sounds; pitch defaults a little above neutral for a livelier read."
            ),
            HelpTopic(
                icon: "mic.and.signal.meter.fill",
                title: "Export AI DJ Set",
                body: "Now Playing's overflow menu (⋯) → Export AI DJ Set bundles an AI DJ Mode listening session — the tracks played plus Aria's own transition lines — into one downloadable set, once there's been a session to export. Only available once AI DJ Mode has actually logged something this session."
            ),
            HelpTopic(
                icon: "questionmark.circle",
                title: "Needle Drop",
                body: "Account → Library → Needle Drop is a music-guessing mini-game built from your own library: a short clip plays from a random point in a random track, and you pick the right title/artist from 4 choices before it fades out. Build a streak — a miss resets it, but your best streak and lifetime record are always saved. Entirely on-device; needs at least 4 songs of a decent length in your library to play."
            ),
            HelpTopic(
                icon: "shippingbox",
                title: "Time Capsules",
                body: "Account → Library → Time Capsules lets you seal a set of songs (from Favorites or an existing playlist) with a short note to your future self, locked until a date you choose. A notification lets you know the moment it unlocks; open it to relive the songs and read the note back. Entirely on-device — nothing about a capsule's contents is sent anywhere."
            ),
            HelpTopic(
                icon: "sparkles",
                title: "Constellation",
                body: "Account → Library → Constellation maps your library as a scatter of genre or artist \"stars\" — bigger stars have more songs. Tap one to shuffle-play it or browse its songs. A different, more visual way to explore your library than the usual lists and grids."
            ),
            HelpTopic(
                icon: "calendar",
                title: "Listening Heatmap",
                body: "Account → Library → Listening Heatmap shows a GitHub-style calendar grid of the last year of listening — darker squares mean more plays that day. A quick way to spot patterns (weekends, late-night streaks, dry spells) that a single stat or leaderboard doesn't show."
            ),
        ]),
        HelpCategory(icon: "lock.shield", title: "Privacy & Security", topics: [
            HelpTopic(
                icon: "faceid",
                title: "App Lock",
                body: "Settings → General → App Lock requires Face ID, Touch ID, or your device passcode to open Lumisound after it's been backgrounded — an extra layer beyond your device's own lock screen, since your account syncs playlists and listening history. Off by default; the option only appears on a device with biometrics or a passcode set up."
            ),
            HelpTopic(
                icon: "key.fill",
                title: "How Your Sign-In Is Protected",
                body: "Your account session is stored in the iOS Keychain — the same hardware-encrypted, OS-protected storage system used for Safari passwords and Apple's own apps, not a plain settings file. It's locked to this specific device, so it can't be resurrected by restoring an iCloud/iTunes backup onto a different phone, and it's inaccessible until the device has been unlocked at least once after a restart. Separately, the app blurs its own screen the instant it loses focus — before iOS captures a thumbnail for the App Switcher — so nothing sensitive sits exposed in the multitasking view even for a moment."
            ),
        ]),
        HelpCategory(icon: "play.circle.fill", title: "Now Playing", topics: [
            HelpTopic(
                icon: "circle.fill",
                title: "Artwork Styles",
                body: "Settings → Appearance lets you switch the whole Now Playing screen's visual treatment for the album art between 25 presets — everything from a spinning Vinyl Groove Spiral or Cassette Reel Spin, to particle/geometric effects like Kaleidoscope Bloom, Mosaic Shatter, and Confetti Burst, to atmospheric looks like Aurora Veil, Bioluminescent Tide, and Frosted Ice Crystal, to retro/glitch treatments like VHS Scan Glitch, Neon Sign Flicker, and Disco Mirror Ball, plus a Live Spectrum analyzer view. Your choice is saved and persists between sessions."
            ),
            HelpTopic(
                icon: "paintbrush.pointed",
                title: "Custom Styles & Hiding Presets",
                body: "Beyond the built-in presets, Settings → Appearance also lets you build your own Now Playing style from scratch — pick colors, layout, and effects — and save it alongside the built-in ones in the picker. If you'd rather trim the picker down to just your favorites, you can hide any built-in preset you don't want to see without deleting it; hidden presets can be brought back the same way at any time."
            ),
            HelpTopic(
                icon: "waveform.badge.clock",
                title: "Timeline & Seeking",
                body: "The timeline slider shows your current position in the track. Drag the thumb to scrub to any point; the elapsed and remaining time labels update in real time while you drag. Release to confirm the seek. The slider is disabled while the duration is unknown (for example at the very start of a stream)."
            ),
            HelpTopic(
                icon: "slider.horizontal.below.rectangle",
                title: "Seeker Styles",
                body: "The scrubber under the artwork isn't fixed — the row of style pills right below it switches between 11 presets: Waveform, Classic, Ring, Bars, Digital, Pill, Neon Line, Dot Track, Segmented, Minimal, and Ruler. Pick Custom to build your own instead of choosing the closest preset — a settings panel appears letting you tune track height, shape (rounded or sharp), color (your accent, a gradient, or plain white), whether the thumb shows at all, and how much it glows. Every change applies live."
            ),
            HelpTopic(
                icon: "heart",
                title: "Favourite Button",
                body: "The heart icon to the right of the track title toggles the current song as a favourite. Favourited songs appear in the Favorites tab in the Library and are included in synced account data. The heart fills with the accent colour when active and springs with a subtle animation on tap."
            ),
            HelpTopic(
                icon: "list.number",
                title: "Up Next Queue",
                body: "The Up Next panel shows the next 10 songs in the queue as a horizontal scroll of artwork thumbnails. The first thumbnail has an accent-coloured border to indicate it plays next. Tap any thumbnail to jump straight to that song. The badge on the panel header shows total queue length and a shuffle icon appears when shuffle is enabled."
            ),
            HelpTopic(
                icon: "quote.bubble",
                title: "Lyrics",
                body: "Tap the lyrics icon on the Now Playing screen to show synced lyrics, if available, in a scrolling panel above the playtime counter. The current line is highlighted and the view auto-scrolls to follow playback; scrolling only animates while a track is playing, and pausing or resuming snaps the view back to the correct line instantly without overshooting. Lyrics are found automatically (a manually synced version you created, a sidecar file next to the audio, then an online database) — but you can also tap Import File in the Lyrics panel to attach your own .lrc (synced) or .txt (plain) file to any track, picked straight from the Files browser. It's recognized automatically whether or not it's correctly timestamped."
            ),
        ]),
        HelpCategory(icon: "apps.iphone", title: "Widgets", topics: [
            HelpTopic(
                icon: "apps.iphone",
                title: "Adding the Widget",
                body: "Long-press the Home Screen or Lock Screen until the icons jiggle, then tap the + button in the top-left corner. Search for \"Lumisound\" in the widget gallery. Choose between the small (1×1) or medium (2×1) size and tap Add Widget. The widget is live and updates automatically whenever the currently playing track changes."
            ),
            HelpTopic(
                icon: "music.note",
                title: "What It Shows",
                body: "The Lumisound widget displays the album artwork, song title, and artist name for the currently playing track. It refreshes through the Darwin notification bridge so changes appear within a second or two of the track changing. If nothing is playing the widget shows the Lumisound logo and a prompt to open the app."
            ),
            HelpTopic(
                icon: "lock.iphone",
                title: "Lock Screen vs Home Screen",
                body: "The Lock Screen widget is a smaller inline or accessory rectangular format that shows the song title and artist in a compact single line. The Home Screen widget is the standard rounded-corner square that shows artwork alongside the track info. Both support Dark Mode and adapt to the current accent colour set in Appearance settings."
            ),
        ]),
    ]
}

// MARK: - SettingsHelpDetailView

private struct SettingsHelpDetailView: View {
    let category: HelpCategory

    var body: some View {
        LKScroll {
            LKSection {
                ForEach(category.topics) { topic in
                    helpRow(icon: topic.icon, title: topic.title, body: topic.body)
                }
            }
        }
        // Without an explicit style this defaults to a grouped-card look —
        // see FavoritesView's identical fix.
        .background(GalleryBackgroundView().ignoresSafeArea())
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.large)
    }

    private func helpRow(icon: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.dynamicAccent)
                    .frame(width: 26, alignment: .center)
                Text(title)
                    .font(AppTheme.headlineFont(size: 15))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            Text(body)
                .font(AppTheme.bodyFont(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 36)
        }
        .padding(.vertical, 6)
    }
}
