#!/usr/bin/env python3
"""Reliable WSS input proxy: browser events -> xdotool or /dev/uinput on Xvfb."""

import asyncio
import json
import os
import ssl
import subprocess
import sys
import time
from pathlib import Path

try:
    import websockets
except ImportError:
    print("[input] python-websockets is required", file=sys.stderr)
    sys.exit(1)

try:
    from uinput_backend import UinputBackend
except ImportError:
    UinputBackend = None  # type: ignore

INPUT_PORT = int(os.environ.get("WEBRTC_INPUT_PORT", "5731"))
TLS_CERT = os.environ.get("TLS_CERT", "/opt/ra2/tls/cert.pem")
TLS_KEY = os.environ.get("TLS_KEY", "/opt/ra2/tls/key.pem")
DISPLAY = os.environ.get("DISPLAY", ":1")
PLAYER_ID = os.environ.get("PLAYER_ID", "1")
INPUT_MOVE_MAX_HZ = max(30, min(250, int(os.environ.get("WEBRTC_INPUT_MOVE_HZ", "125"))))
INPUT_MOVE_MIN_INTERVAL = 1.0 / INPUT_MOVE_MAX_HZ
INPUT_BACKEND = os.environ.get("WEBRTC_INPUT_BACKEND", "xdotool").strip().lower()
UINPUT_DEVICE = os.environ.get("UINPUT_DEVICE", "/dev/uinput")
VIDEO_WIDTH = max(1, int(os.environ.get("WEBRTC_VIDEO_WIDTH", "1024")))
VIDEO_HEIGHT = max(1, int(os.environ.get("WEBRTC_VIDEO_HEIGHT", "768")))


def _ssl_context():
    if os.environ.get("WEBRTC_INPUT_TLS", "0") != "1":
        return None
    if not (Path(TLS_CERT).is_file() and Path(TLS_KEY).is_file()):
        return None
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(TLS_CERT, TLS_KEY)
    return ctx


def _run_xdotool(args):
    env = {**os.environ, "DISPLAY": DISPLAY}
    try:
        subprocess.run(
            ["xdotool", *args],
            env=env,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=2,
        )
    except Exception as exc:
        print(f"[input] xdotool failed: {exc}", flush=True)


def _resolve_backend() -> str:
    if INPUT_BACKEND in {"xdotool", "uinput"}:
        return INPUT_BACKEND
    if INPUT_BACKEND == "auto":
        if UinputBackend and UinputBackend.available(UINPUT_DEVICE):
            return "uinput"
        return "xdotool"
    print(f"[input] unknown WEBRTC_INPUT_BACKEND={INPUT_BACKEND}; using xdotool", flush=True)
    return "xdotool"


class InputSession:
    def __init__(self) -> None:
        self.last_move_at = 0.0
        self.move_sent = 0
        self.move_dropped = 0
        self.stats_window_start = time.monotonic()
        self.backend_name = _resolve_backend()
        self.uinput: UinputBackend | None = None
        if self.backend_name == "uinput":
            if not UinputBackend:
                print("[input] uinput backend unavailable; falling back to xdotool", flush=True)
                self.backend_name = "xdotool"
            else:
                try:
                    self.uinput = UinputBackend(UINPUT_DEVICE, VIDEO_WIDTH, VIDEO_HEIGHT)
                    self.uinput.open()
                except Exception as exc:
                    print(f"[input] uinput open failed ({exc}); falling back to xdotool", flush=True)
                    self.backend_name = "xdotool"
                    self.uinput = None
        print(f"[input] using backend={self.backend_name} (player {PLAYER_ID})", flush=True)

    def close(self) -> None:
        if self.uinput:
            self.uinput.close()
            self.uinput = None

    def _maybe_log_stats(self) -> None:
        now = time.monotonic()
        elapsed = now - self.stats_window_start
        if elapsed < 10:
            return
        rate = self.move_sent / elapsed if elapsed > 0 else 0.0
        print(
            f"[input] backend={self.backend_name} move rate {rate:.0f}/s "
            f"dropped={self.move_dropped} cap={INPUT_MOVE_MAX_HZ}Hz (player {PLAYER_ID})",
            flush=True,
        )
        self.move_sent = 0
        self.move_dropped = 0
        self.stats_window_start = now

    def handle_event(self, event: dict) -> None:
        kind = event.get("type")
        if kind == "debug":
            message = str(event.get("message", ""))[:500]
            print(f"[input] browser debug: {message}", flush=True)
            return
        if kind == "mousemove":
            now = time.monotonic()
            if now - self.last_move_at < INPUT_MOVE_MIN_INTERVAL:
                self.move_dropped += 1
                self._maybe_log_stats()
                return
            self.last_move_at = now
            self.move_sent += 1
            self._maybe_log_stats()
            x = int(event.get("x", 0))
            y = int(event.get("y", 0))
            if self.uinput:
                self.uinput.mousemove(x, y)
            else:
                _run_xdotool(["mousemove", str(x), str(y)])
            return
        if kind == "mousedown":
            x = int(event.get("x", 0))
            y = int(event.get("y", 0))
            button = int(event.get("button", 1))
            if self.uinput:
                self.uinput.mousedown(x, y, button)
            else:
                _run_xdotool(["mousemove", str(x), str(y)])
                _run_xdotool(["mousedown", str(button)])
            return
        if kind == "mouseup":
            x = int(event.get("x", 0))
            y = int(event.get("y", 0))
            button = int(event.get("button", 1))
            if self.uinput:
                self.uinput.mouseup(x, y, button)
            else:
                if "x" in event and "y" in event:
                    _run_xdotool(["mousemove", str(x), str(y)])
                _run_xdotool(["mouseup", str(button)])
            return
        if kind == "click":
            x = int(event.get("x", 0))
            y = int(event.get("y", 0))
            button = int(event.get("button", 1))
            if self.uinput:
                self.uinput.click(x, y, button)
            else:
                _run_xdotool(["mousemove", str(x), str(y)])
                _run_xdotool(["click", str(button)])
            return
        if kind == "keydown":
            key = event.get("key")
            if not key:
                return
            if self.uinput:
                self.uinput.keydown(key)
            else:
                _run_xdotool(["keydown", key])
            return
        if kind == "keyup":
            key = event.get("key")
            if not key:
                return
            if self.uinput:
                self.uinput.keyup(key)
            else:
                _run_xdotool(["keyup", key])
            return
        if kind == "wheel":
            delta_y = int(event.get("deltaY", 0))
            if self.uinput:
                self.uinput.wheel(delta_y)
            else:
                direction = "4" if delta_y < 0 else "5"
                _run_xdotool(["click", direction])


async def handle_client(websocket):
    session = InputSession()
    print(f"[input] client connected (player {PLAYER_ID})", flush=True)
    try:
        async for raw in websocket:
            try:
                event = json.loads(raw)
                session.handle_event(event)
            except json.JSONDecodeError:
                continue
    finally:
        session.close()
        print(f"[input] client disconnected (player {PLAYER_ID})", flush=True)


async def main():
    if os.environ.get("WEBRTC_ENABLED", "0") != "1":
        print("[input] WEBRTC_ENABLED is not set; exiting", flush=True)
        return

    ssl_ctx = _ssl_context()
    scheme = "wss" if ssl_ctx else "ws"
    print(
        f"[input] listening on {scheme}://0.0.0.0:{INPUT_PORT} "
        f"(player {PLAYER_ID}, backend={_resolve_backend()}, move cap {INPUT_MOVE_MAX_HZ}Hz)",
        flush=True,
    )
    async with websockets.serve(handle_client, "0.0.0.0", INPUT_PORT, ssl=ssl_ctx):
        await asyncio.Future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
