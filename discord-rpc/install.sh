#!/usr/bin/env bash
# Sets up the Lumisound Discord Rich Presence daemon as a systemd --user service.
#
# This is the only thing most people need to run. Everything else (Discord
# Application client ID, art asset, on/off) comes from your account's
# server-side registration in Lumisound -> Account -> Discord Rich Presence.
#
# Usage:
#   ./install.sh                     # sign in with email/username + password
#   ./install.sh <rpc_token>         # or paste a Rich Presence token
#   ./install.sh <rpc_token> <url>   # ...against a self-hosted bridge
#   ./install.sh --bridge-url <url>  # sign in against a self-hosted bridge
#   ./install.sh --config-only       # write config.json, touch no units
#   ./install.sh --force             # proceed despite a managed-unit warning
#
# Signing in is the default because the Rich Presence token is 248 characters
# and pasting it reliably is awkward. Your password is exchanged for a 365-day
# token and is never written to disk -- see `lumisound-discord-rpc login` (rust/rpc/src/login.rs).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_NAME="lumisound-discord-rpc.service"
UNIT_DEST="$SYSTEMD_USER_DIR/$UNIT_NAME"

die() { echo "Error: $*" >&2; exit 1; }
warn() { echo "Warning: $*" >&2; }

FORCE=0
CONFIG_ONLY=0
LOGIN_ARGS=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --force)       FORCE=1; shift ;;
        --config-only) CONFIG_ONLY=1; shift ;;
        --bridge-url)
            [ "$#" -ge 2 ] || die "--bridge-url needs a URL."
            LOGIN_ARGS+=(--bridge-url "$2"); shift 2 ;;
        --identifier)
            [ "$#" -ge 2 ] || die "--identifier needs an email or username."
            LOGIN_ARGS+=(--identifier "$2"); shift 2 ;;
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
        -*) die "Unknown option: $1" ;;
        *)
            # Positional form, kept for anyone following the older instructions:
            #   install.sh <rpc_token> [bridge_url]
            LOGIN_ARGS+=(--token "$1")
            [ -n "${2:-}" ] && { LOGIN_ARGS+=(--bridge-url "$2"); shift; }
            shift ;;
    esac
done

# --- guards ----------------------------------------------------------------

[ "$(id -u)" -ne 0 ] || die "Do not run this as root. It installs a *user* service; \
as root it would configure root's account, not yours."

# The daemon is a single Rust binary (rust/rpc). Use a downloaded release
# binary next to this script, one on PATH, or build it from this checkout.
find_bin() {
    if [ -x "$SCRIPT_DIR/lumisound-discord-rpc" ]; then echo "$SCRIPT_DIR/lumisound-discord-rpc"; return; fi
    if command -v lumisound-discord-rpc >/dev/null 2>&1; then command -v lumisound-discord-rpc; return; fi
    if command -v cargo >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/../rust/rpc/Cargo.toml" ]; then
        echo "Building lumisound-discord-rpc with cargo (one time)..." >&2
        (cd "$SCRIPT_DIR/../rust" && cargo build --release -p lumisound-rpc >&2) \
            && cp "$SCRIPT_DIR/../rust/target/release/lumisound-discord-rpc" "$SCRIPT_DIR/" \
            && echo "$SCRIPT_DIR/lumisound-discord-rpc" && return
    fi
    return 1
}
BIN="$(find_bin)" || die "lumisound-discord-rpc not found. Download it from the Lumisound \
GitHub releases into $SCRIPT_DIR, or install Rust (https://rustup.rs) so it can be built."
[ -f "$SCRIPT_DIR/$UNIT_NAME" ] \
    || die "$UNIT_NAME template is missing from $SCRIPT_DIR."

if [ "$CONFIG_ONLY" -eq 0 ]; then
    command -v systemctl >/dev/null 2>&1 \
        || die "systemctl not found. This installer targets systemd. Use \
--config-only and start lumisound-discord-rpc however your system does \
services (see install-macos.sh for a LaunchAgent example)."

    # A user service needs a running user manager. Absent under plain `su`, in
    # most containers, and on WSL1 / WSL2 without systemd enabled -- where
    # `systemctl --user` fails with "Failed to connect to bus".
    systemctl --user show-environment >/dev/null 2>&1 \
        || die "No systemd user session (systemctl --user cannot reach its bus). \
On WSL, enable systemd in /etc/wsl.conf; over SSH, log in properly or use \
'machinectl shell'. Or re-run with --config-only."

    # The footgun this guard exists for: on NixOS / Guix / home-manager the
    # unit is generated declaratively into /etc/systemd/user (or
    # /run/systemd/user). A unit in ~/.config/systemd/user takes PRECEDENCE
    # over those, so writing one here silently detaches the service from the
    # tool that manages it -- the next rebuild appears to do nothing, because
    # this copy keeps winning.
    for managed_dir in /etc/systemd/user /run/systemd/user /usr/lib/systemd/user; do
        if [ -e "$managed_dir/$UNIT_NAME" ] && [ ! -L "$UNIT_DEST" ]; then
            if [ "$FORCE" -eq 1 ]; then
                warn "$managed_dir/$UNIT_NAME exists; --force given, shadowing it with $UNIT_DEST."
            else
                cat >&2 <<EOF
Error: $UNIT_NAME is already provided system-wide at
       $managed_dir/$UNIT_NAME

That usually means it is managed declaratively (NixOS, home-manager, Guix, or
a distro package). A unit in $SYSTEMD_USER_DIR overrides it, so installing
here would detach the service from whatever manages it, and later rebuilds
would silently have no effect.

What you probably want instead:
  ./install.sh --config-only     # just sign in and write config.json
                                 # then: systemctl --user restart $UNIT_NAME

If you really do want to shadow the managed unit, re-run with --force.
EOF
                exit 1
            fi
        fi
    done
fi

# --- sign in / write config ------------------------------------------------

# Writes the config (mode 0600) at the daemon's own default_config_path().
"$BIN" login "${LOGIN_ARGS[@]+"${LOGIN_ARGS[@]}"}"

if [ "$CONFIG_ONLY" -eq 1 ]; then
    echo
    echo "Config written; no service files touched (--config-only)."
    echo "If the service is already installed, pick up the new token with:"
    echo "  systemctl --user restart $UNIT_NAME"
    exit 0
fi

# --- install the unit ------------------------------------------------------

mkdir -p "$SYSTEMD_USER_DIR"

# Point the service at this checkout (works wherever it was cloned to).
sed "s#__BIN_PATH__#$BIN#" \
    "$SCRIPT_DIR/$UNIT_NAME" > "$UNIT_DEST"
echo "Installed $UNIT_DEST"

systemctl --user daemon-reload
systemctl --user enable --now "$UNIT_NAME"

echo
echo "Service started. Check status with:"
echo "  systemctl --user status $UNIT_NAME"
echo "  journalctl --user -u $UNIT_NAME -f"
