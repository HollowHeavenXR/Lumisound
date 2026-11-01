# Lumisound Discord Rich Presence

A small daemon that mirrors your Lumisound "now playing" state to your
Discord profile via Rich Presence. It is one self-contained Rust binary,
`lumisound-discord-rpc` (source: [`rust/rpc`](../rust/rpc)) — no Python or
other runtime needed. The installers below use a release binary placed next
to them, one on your `PATH`, or build it once with `cargo` if Rust is
installed.

## Why this can't be fully server-side

Discord's Rich Presence (the "Playing/Listening to..." card on a profile) is
only settable over Discord's **local IPC** — a Unix socket (or, on Windows, a
named pipe) that the Discord desktop client opens on the machine it's running
on. There is no Discord API that lets a remote server set another account's
Rich Presence directly; the only first-party way is this local connection.

So **something has to run next to your Discord desktop client** — there's no
way around that part. What Lumisound *does* centralize is everything else:
your Discord Application Client ID, Rich Presence art, and the on/off toggle
all live on the Lumisound server (`/user/discord-rpc-config`, set from
**Account → Discord Rich Presence**) and the daemon fetches them
automatically. Locally you just **sign in and run one script** — see below.

## 1. Register your Discord app (once)

In the app, go to **Account → Discord Rich Presence** and enter a **Discord
Application Client ID** (create one for free at
https://discord.com/developers/applications — only the name/icon matter), plus
optionally a Rich Presence art asset name, then save. This is stored
server-side, so the daemon picks it up automatically — nothing to copy into a
config file.

That's all you need here. You do **not** have to generate a token by hand
anymore — the installer signs in for you.

## 2. Run the daemon

Pick your platform and sign in with your **Lumisound email (or username) and
password** when prompted. Everything else has a sensible default (the hosted
Lumisound bridge) or comes from your server-side registration.

Your password is **never saved**. The installer exchanges it for a 365-day
Rich Presence token which is all that gets written to disk (mode `0600`). That
token only allows reading your own playback state, and you can revoke it any
time from **Account → Active Sessions** ("Discord RPC Bridge") without
changing your password.

If your account has **two-factor authentication**, the installer will prompt
for your 6-digit code and complete the login normally.

### Linux (systemd --user service)

```sh
./install.sh
```

Manage it with:

```sh
systemctl --user status lumisound-discord-rpc.service
journalctl --user -u lumisound-discord-rpc.service -f
```

**After updating the binary** (a new release or a rebuild), the running
process keeps executing the old one until you restart it:

```sh
systemctl --user restart lumisound-discord-rpc.service
```

A missed restart here looks exactly like the fix didn't work.

**On NixOS, home-manager, or Guix**, the unit is generated declaratively and a
copy in `~/.config/systemd/user` would override it — so `install.sh` refuses
and points you at:

```sh
./install.sh --config-only      # sign in, write config.json, touch no units
systemctl --user restart lumisound-discord-rpc.service
```

Pass `--force` to shadow the managed unit anyway (rarely what you want).

### macOS (LaunchAgent, starts at login)

```sh
./install-macos.sh
```

Manage it with:

```sh
launchctl list | grep lumisound
tail -f ~/.config/lumisound-discord-rpc/daemon.log
```

### Windows (Scheduled Task, starts at login)

Put `lumisound-discord-rpc.exe` next to the script (or install Rust so it can
be built). In PowerShell:

```powershell
.\install-windows.ps1
```

Manage it with:

```powershell
Get-ScheduledTask -TaskName LumisoundDiscordRPC
```

### Manual / any platform

Sign in without installing a service, then run the daemon in the foreground:

```sh
lumisound-discord-rpc login   # writes config.json (mode 0600) for you
lumisound-discord-rpc
```

### Still prefer a token?

The old flow works unchanged. Generate one from **Account → Discord Rich
Presence → Generate Rich Presence Token**, then:

```sh
./install.sh <rpc_token>                       # Linux
./install-macos.sh <rpc_token>                 # macOS
.\install-windows.ps1 -Token "<rpc_token>"     # Windows
```

Or write it yourself — note the config path differs on Windows:

```sh
# Linux / macOS
mkdir -p ~/.config/lumisound-discord-rpc
echo '{"access_token": "<rpc_token>"}' > ~/.config/lumisound-discord-rpc/config.json
```

```powershell
# Windows: %APPDATA%\lumisound-discord-rpc\config.json
```

Set `LUMISOUND_RPC_CONFIG` to use a different path entirely.

If you're self-hosting the ios-bridge instead of using the hosted one, add
`"bridge_url": "https://your-bridge-host.example.com"` to `config.json`, or
pass `--bridge-url https://...` to the install scripts.

## How it works

The daemon polls `GET /user/playback-state` on the bridge. Whenever
Lumisound's iOS app reports a track via the existing playback-state sync,
this daemon picks it up and calls `SET_ACTIVITY` over Discord's local IPC,
showing:

- **Details**: track title
- **State**: `by <artist>`
- **Timestamps**: elapsed/remaining bar based on `position_seconds` /
  `duration_seconds`

If playback is paused or the last update is older than 2 minutes (app
backgrounded/closed), the Rich Presence is cleared.

If you would rather keep a paused track on screen (without the elapsed timer),
set `"show_when_paused": true` in your config.
