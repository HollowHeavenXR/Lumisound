#!/usr/bin/env python3
"""
Lumisound Discord Rich Presence bridge.
"""

from __future__ import annotations

import json
import os
import platform
import socket
import struct
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime
from pathlib import Path
from typing import Optional

IS_WINDOWS = platform.system() == "Windows"

OP_HANDSHAKE = 0
OP_FRAME = 1
OP_CLOSE = 2
OP_PING = 3
OP_PONG = 4

def default_config_path() -> Path:
    override = os.environ.get("LUMISOUND_RPC_CONFIG")
    if override:
        return Path(override)
    legacy = Path.home() / ".config" / "lumisound-discord-rpc" / "config.json"
    if os.name == "nt":
        appdata = os.environ.get("APPDATA")
        if appdata:
            win = Path(appdata) / "lumisound-discord-rpc" / "config.json"
            return legacy if (legacy.exists() and not win.exists()) else win
        return legacy
    xdg = os.environ.get("XDG_CONFIG_HOME")
    if xdg:
        return Path(xdg) / "lumisound-discord-rpc" / "config.json"
    return legacy

DEFAULT_CONFIG_PATH = default_config_path()
DEFAULT_BRIDGE_URL = "https://lumisound-bridge.xenusanimations.studio"

def log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"{ts}  {msg}", flush=True)

def _candidate_ipc_paths() -> list[str]:
    if IS_WINDOWS:
        return [rf"\\.\pipe\discord-ipc-{i}" for i in range(10)]
    bases = []
    for var in ("XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"):
        val = os.environ.get(var)
        if val:
            bases.append(val)
    bases.append("/tmp")
    paths = []
    for base in bases:
        paths.append(base)
        paths.append(os.path.join(base, "app", "com.discordapp.Discord"))
        paths.append(os.path.join(base, "snap.discord"))
    sockets = []
    for base in paths:
        for i in range(10):
            sockets.append(os.path.join(base, f"discord-ipc-{i}"))
    return sockets

class DiscordIPCError(Exception):
    pass

class DiscordIPC:
    def __init__(self, client_id: str):
        self.client_id = client_id
        self.sock: Optional[socket.socket] = None
        self.pipe = None

    def connect(self) -> None:
        if IS_WINDOWS:
            for path in _candidate_ipc_paths():
                try:
                    pipe = open(path, "r+b", buffering=0)
                except OSError:
                    continue
                self.pipe = pipe
                self._handshake()
                log(f"Connected to Discord IPC at {path}")
                return
            raise DiscordIPCError("No Discord IPC pipe found")
        for path in _candidate_ipc_paths():
            if not os.path.exists(path):
                continue
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                sock.connect(path)
            except OSError:
                sock.close()
                continue
            self.sock = sock
            self._handshake()
            log(f"Connected to Discord IPC at {path}")
            return
        raise DiscordIPCError("No Discord IPC socket found")

    def _write(self, data: bytes) -> None:
        if self.pipe:
            self.pipe.write(data)
        elif self.sock:
            self.sock.sendall(data)
        else:
            raise DiscordIPCError("Not connected")

    def _read(self, n: int) -> bytes:
        if self.pipe:
            return self.pipe.read(n)
        if self.sock:
            return self.sock.recv(n)
        raise DiscordIPCError("Not connected")

    def _send(self, opcode: int, payload: dict) -> None:
        data = json.dumps(payload).encode("utf-8")
        self._write(struct.pack("<II", opcode, len(data)) + data)

    def _recv(self) -> tuple[int, dict]:
        header = self._recv_exact(8)
        opcode, length = struct.unpack("<II", header)
        body = self._recv_exact(length)
        try:
            return opcode, json.loads(body.decode("utf-8"))
        except json.JSONDecodeError:
            return opcode, {}

    def _recv_exact(self, n: int) -> bytes:
        chunks = []
        remaining = n
        while remaining > 0:
            chunk = self._read(remaining)
            if not chunk:
                raise DiscordIPCError("Discord IPC connection closed")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    @property
    def connected(self) -> bool:
        return self.sock is not None or self.pipe is not None

    def _handshake(self) -> None:
        self._send(OP_HANDSHAKE, {"v": 1, "client_id": self.client_id})
        opcode, payload = self._recv()
        if payload.get("evt") != "READY":
            raise DiscordIPCError(f"Unexpected handshake response: {payload}")

    def set_activity(self, activity: Optional[dict]) -> None:
        self._send(OP_FRAME, {"cmd": "SET_ACTIVITY", "args": {"pid": os.getpid(), "activity": activity}, "nonce": str(uuid.uuid4())})
        self._recv()

    def clear_activity(self) -> None:
        self.set_activity(None)

    def close(self) -> None:
        if self.sock:
            try: self._send(OP_CLOSE, {})
            except OSError: pass
            self.sock.close()
            self.sock = None
        if self.pipe:
            try: self._send(OP_CLOSE, {})
            except OSError: pass
            self.pipe.close()
            self.pipe = None

class BridgeClient:
    def __init__(self, base_url: str, config_path: Path, config: dict):
        self.base_url = base_url.rstrip("/")
        self.config_path = config_path
        self.config = config
        self.access_token: Optional[str] = config.get("access_token")

    def _request(self, method: str, path: str, body: Optional[dict] = None, auth: bool = True) -> dict:
        url = f"{self.base_url}{path}"
        data = json.dumps(body).encode("utf-8") if body is not None else None
        headers = {"Content-Type": "application/json", "User-Agent": "lumisound-discord-rpc/1.0"}
        if auth and self.access_token:
            headers["Authorization"] = f"Bearer {self.access_token}"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}

    def login(self) -> None:
        username = self.config.get("username")
        password = self.config.get("password")
        if not username or not password:
            raise DiscordIPCError("No access_token/credentials.")
        result = self._request("POST", "/auth/login", {"username": username, "password": password, "device_name": "Discord RPC Bridge"}, auth=False)
        self.access_token = result["token"]
        try:
            rpc = self._request("POST", "/user/rpc-token")
            if rpc.get("token"): self.access_token = rpc["token"]
        except: pass
        self.config["access_token"] = self.access_token
        self.config_path.write_text(json.dumps(self.config, indent=2))
        os.chmod(self.config_path, 0o600)

    def get_playback_state(self) -> Optional[dict]:
        if not self.access_token: self.login()
        try: return self._request("GET", "/user/playback-state")
        except urllib.error.HTTPError as exc:
            if exc.code == 401:
                self.login()
                return self._request("GET", "/user/playback-state")
            raise

    def get_rpc_config(self) -> Optional[dict]:
        if not self.access_token: self.login()
        try: return self._request("GET", "/user/discord-rpc-config")
        except urllib.error.HTTPError as exc:
            if exc.code == 401:
                self.login()
                return self._request("GET", "/user/discord-rpc-config")
            raise

STALE_AFTER_SECONDS = 120
OUTAGE_REMINDER_SECONDS = 30 * 60
MIN_SEND_INTERVAL_SECONDS = 4.5

def _sampled_at_epoch(state: dict) -> Optional[float]:
    """Parses the bridge's `updated_at` (ISO 8601 with an explicit UTC
    offset — see get_playback_state's own doc comment on why that offset
    matters) into a Unix epoch, i.e. the wall-clock moment `position_seconds`
    was actually true on the phone — NOT whenever this daemon happens to be
    polling. `None` if missing/unparseable, so the caller can fall back."""
    raw = state.get("updated_at")
    if not raw: return None
    try: return datetime.fromisoformat(raw).timestamp()
    except ValueError: return None

def build_activity(state: dict, large_image: Optional[str], small_image: Optional[str] = None, show_buttons: bool = True, show_when_paused: bool = False) -> Optional[dict]:
    if not state or not state.get("title"): return None
    is_playing = bool(state.get("is_playing", False))
    if not is_playing and not show_when_paused: return None
    # BUGFIX (reported: "the last known track I was playing is still going,
    # even after I closed the app"): `STALE_AFTER_SECONDS` was defined but
    # never actually checked anywhere — this function trusted whatever
    # `is_playing`/`position_seconds` the bridge last had on file, with no
    # way to tell "genuinely still playing" apart from "the app got force-
    # quit (or crashed, or the OS killed it, or the battery died) before it
    # ever got a chance to push a final stopped state." iOS gives an app no
    # guaranteed opportunity to clean up on termination, so the daemon
    # polling a possibly-stale row is the only place this can actually be
    # caught — not something the app can be relied on to always prevent by
    # pushing one more update on its way out. A row that hasn't been
    # refreshed in over `STALE_AFTER_SECONDS` means nothing on the phone has
    # reported in for two full minutes — long enough that no real,
    # currently-running session looks like this (steady playback pushes
    # every ~5s; even a pause/seek pushes immediately) — so treat it as
    # "nothing is actually playing" rather than keep showing it.
    sampled_at = _sampled_at_epoch(state)
    if sampled_at is not None and time.time() - sampled_at > STALE_AFTER_SECONDS:
        return None
    activity = {"type": 2, "details": (state.get("title") or "")[:128]}
    if state.get("artist"): activity["state"] = f"by {state['artist']}"[:128]
    if is_playing:
        position = state.get("position_seconds") or 0
        # BUGFIX (reported: Discord's shown elapsed time is "always a few
        # ticks behind" the real playback position): this used `time.time()`
        # — the moment THIS DAEMON happens to poll — instead of the moment
        # `position_seconds` was actually sampled on the phone. The iOS app
        # only pushes playback state every ~5s during steady playback (see
        # AudioPlayerManager+PositionTracking's bridgePushTickCounter), so
        # `position_seconds` is routinely a few seconds stale by the time
        # this daemon reads it — recomputing `start` from the CURRENT time
        # against a STALE position baked that staleness into `start` itself,
        # on every single poll. `start` only needs to be computed once per
        # sample, from when the sample was actually true; Discord's own
        # client then ticks the displayed time forward live from that fixed
        # epoch with no further input from here, so it reads accurately
        # regardless of how infrequently the phone pushes or this daemon
        # polls. Falls back to `time.time()` if `updated_at` is missing
        # (older bridge response shape) rather than failing outright.
        sampled_at = _sampled_at_epoch(state) or time.time()
        activity["timestamps"] = {"start": int(sampled_at - position)}
    track_art = state.get("artwork_url")
    assets = {}
    if track_art or large_image:
        assets["large_image"] = track_art or large_image
        assets["large_text"] = (state.get("title") or "Lumisound")[:128] if track_art else "Lumisound"
    if small_image and track_art:
        assets["small_image"] = small_image
        assets["small_text"] = "Playing" if is_playing else "Paused"
    if assets: activity["assets"] = assets
    if show_buttons and state.get("track_url"):
        activity["buttons"] = [{"label": "Listen", "url": state["track_url"]}]
    return activity

def load_config(config_path: Path) -> dict:
    if not config_path.exists(): sys.exit(1)
    return json.loads(config_path.read_text())

def main() -> None:
    config_path = Path(os.environ.get("LUMISOUND_RPC_CONFIG", DEFAULT_CONFIG_PATH))
    config = load_config(config_path)
    bridge = BridgeClient(config.get("bridge_url") or DEFAULT_BRIDGE_URL, config_path, config)
    
    # At login the bridge (Docker in WSL) may not be reachable yet (HTTP 530/timeouts);
    # keep retrying instead of exiting.
    while True:
        try:
            rpc_config = bridge.get_rpc_config()
            break
        except Exception as exc:
            log(f"bridge not ready ({exc!r}); retrying in 10s")
            time.sleep(10)
    client_id = config.get("discord_client_id") or (rpc_config.get("discord_client_id") if rpc_config else None)
    
    ipc = DiscordIPC(client_id)
    last_activity_signature = None
    last_sent_at = 0.0
    last_rpc_check = time.time()
    # Default tightened from 2s: the bridge has no caching of its own (a
    # fresh GET /user/playback-state always reflects whatever the phone last
    # PUT — see ios-bridge's get_playback_state, direct DB read, no TTL
    # cache) and the iOS app already pushes every real event (track change/
    # play-pause/seek) to the bridge SYNCHRONOUSLY the instant it happens
    # (AudioPlayerManager's isPlaying/currentSong didSet and seek() all call
    # pushPlaybackStateToBridge() directly, not just the ~5s steady-playback
    # tick). So once an event lands on the bridge, THIS poll loop is the
    # only remaining source of lag before Discord sees it — at the old 2s
    # interval that is up to 2 full seconds of "obviously stale, should be
    # instant" delay on every track/play-pause change, on top of whatever
    # the network round-trip costs. Halving it to 1s halves that worst case
    # for one extra lightweight GET/sec against a single indexed row — a
    # fair trade, and still well short of hammering the bridge.
    poll_interval = config.get("poll_interval_seconds", 1)

    while True:
        if time.time() - last_rpc_check > 300:
            try:
                new_rpc = bridge.get_rpc_config()
            except Exception as exc:
                log(f"rpc-config refresh failed ({exc!r}); keeping current client id")
                new_rpc = None
            if new_rpc and new_rpc.get("discord_client_id") != client_id:
                client_id = new_rpc["discord_client_id"]
                ipc.close()
                ipc = DiscordIPC(client_id)
            last_rpc_check = time.time()

        try:
            if not ipc.connected: ipc.connect()
        except:
            time.sleep(poll_interval)
            continue

        try:
            state = bridge.get_playback_state()
        except Exception as exc:
            # A single timeout/5xx from the bridge used to kill the whole daemon.
            log(f"bridge request failed ({exc!r}); retrying")
            time.sleep(poll_interval)
            continue
        activity = build_activity(state, config.get("large_image"), config.get("small_image"))
        signature = (activity.get("details"), activity.get("state")) if activity else None
        now = time.time()
        
        if signature != last_activity_signature or now - last_sent_at >= MIN_SEND_INTERVAL_SECONDS:
            try:
                if activity is None:
                    ipc.clear_activity()
                else:
                    ipc.set_activity(activity)
                last_sent_at = now
                last_activity_signature = signature
            except: ipc.close()
        time.sleep(poll_interval)

if __name__ == "__main__":
    main()

