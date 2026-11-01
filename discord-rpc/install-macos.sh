#!/usr/bin/env bash
# Sets up the Lumisound Discord Rich Presence daemon as a macOS LaunchAgent
# (runs in the background, restarts on login).
#
# Usage:
#   ./install-macos.sh                     # sign in with email/username + password
#   ./install-macos.sh <rpc_token>         # or paste a Rich Presence token
#   ./install-macos.sh <rpc_token> <url>   # ...against a self-hosted bridge
#   ./install-macos.sh --bridge-url <url>  # sign in against a self-hosted bridge
#
# Signing in is the default because the Rich Presence token is 248 characters
# and pasting it reliably is awkward. Your password is exchanged for a 365-day
# token and is never written to disk -- see `lumisound-discord-rpc login`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST="$LAUNCH_AGENTS_DIR/com.lumisound.discord-rpc.plist"
# Same place the daemon reads config.json from (LUMISOUND_RPC_CONFIG overrides it).
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/lumisound-discord-rpc"
mkdir -p "$CONFIG_DIR"

# The daemon is a single Rust binary (rust/rpc): a downloaded release binary
# next to this script, one on PATH, or built from this checkout with cargo.
if [ -x "$SCRIPT_DIR/lumisound-discord-rpc" ]; then
    BIN="$SCRIPT_DIR/lumisound-discord-rpc"
elif command -v lumisound-discord-rpc >/dev/null 2>&1; then
    BIN="$(command -v lumisound-discord-rpc)"
elif command -v cargo >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/../rust/rpc/Cargo.toml" ]; then
    echo "Building lumisound-discord-rpc with cargo (one time)..."
    (cd "$SCRIPT_DIR/../rust" && cargo build --release -p lumisound-rpc)
    cp "$SCRIPT_DIR/../rust/target/release/lumisound-discord-rpc" "$SCRIPT_DIR/"
    BIN="$SCRIPT_DIR/lumisound-discord-rpc"
else
    echo "Error: lumisound-discord-rpc not found. Download it from the Lumisound GitHub releases into $SCRIPT_DIR, or install Rust (https://rustup.rs)." >&2
    exit 1
fi

LOGIN_ARGS=()
case "${1:-}" in
    "")
        # Interactive sign-in.
        ;;
    --bridge-url)
        [ "$#" -ge 2 ] || { echo "Error: --bridge-url needs a URL." >&2; exit 1; }
        LOGIN_ARGS+=(--bridge-url "$2")
        ;;
    -h|--help)
        sed -n '2,13p' "$0"
        exit 0
        ;;
    *)
        # Positional form, kept for anyone following the older instructions:
        #   install-macos.sh <rpc_token> [bridge_url]
        LOGIN_ARGS+=(--token "$1")
        [ -n "${2:-}" ] && LOGIN_ARGS+=(--bridge-url "$2")
        ;;
esac

mkdir -p "$LAUNCH_AGENTS_DIR"

# Writes the config (mode 0600) at the daemon's own default_config_path().
python3 "$SCRIPT_DIR/rpc_login.py" "${LOGIN_ARGS[@]+"${LOGIN_ARGS[@]}"}"

PYTHON3="$(command -v python3)"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.lumisound.discord-rpc</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$CONFIG_DIR/daemon.log</string>
    <key>StandardErrorPath</key>
    <string>$CONFIG_DIR/daemon.log</string>
</dict>
</plist>
PLIST_EOF

echo "Installed $PLIST"

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo
echo "Started. Check status with:"
echo "  launchctl list | grep lumisound"
echo "  tail -f $CONFIG_DIR/daemon.log"
echo
echo "Stop with:"
echo "  launchctl unload $PLIST"
