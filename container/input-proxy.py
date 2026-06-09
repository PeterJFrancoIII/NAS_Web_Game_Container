#!/usr/bin/env python3
"""Reliable WSS input proxy: browser events -> xdotool on Xvfb."""

import asyncio
import json
import os
import ssl
import subprocess
import sys
from pathlib import Path

try:
    import websockets
except ImportError:
    print("[input] python-websockets is required", file=sys.stderr)
    sys.exit(1)

INPUT_PORT = int(os.environ.get("WEBRTC_INPUT_PORT", "5731"))
TLS_CERT = os.environ.get("TLS_CERT", "/opt/ra2/tls/cert.pem")
TLS_KEY = os.environ.get("TLS_KEY", "/opt/ra2/tls/key.pem")
DISPLAY = os.environ.get("DISPLAY", ":1")
PLAYER_ID = os.environ.get("PLAYER_ID", "1")


def _ssl_context():
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


def _handle_event(event):
    kind = event.get("type")
    if kind == "mousemove":
        _run_xdotool(["mousemove", str(int(event.get("x", 0))), str(int(event.get("y", 0)))])
    elif kind == "mousedown":
        _run_xdotool(["mousemove", str(int(event.get("x", 0))), str(int(event.get("y", 0)))])
        _run_xdotool(["mousedown", str(int(event.get("button", 1)))])
    elif kind == "mouseup":
        _run_xdotool(["mouseup", str(int(event.get("button", 1)))])
    elif kind == "click":
        _run_xdotool(["mousemove", str(int(event.get("x", 0))), str(int(event.get("y", 0)))])
        _run_xdotool(["click", str(int(event.get("button", 1)))])
    elif kind == "keydown":
        key = event.get("key")
        if key:
            _run_xdotool(["keydown", key])
    elif kind == "keyup":
        key = event.get("key")
        if key:
            _run_xdotool(["keyup", key])
    elif kind == "wheel":
        direction = "4" if int(event.get("deltaY", 0)) < 0 else "5"
        _run_xdotool(["click", direction])


async def handle_client(websocket):
    print(f"[input] client connected (player {PLAYER_ID})", flush=True)
    try:
        async for raw in websocket:
            try:
                event = json.loads(raw)
                _handle_event(event)
            except json.JSONDecodeError:
                continue
    finally:
        print(f"[input] client disconnected (player {PLAYER_ID})", flush=True)


async def main():
    if os.environ.get("WEBRTC_ENABLED", "0") != "1":
        print("[input] WEBRTC_ENABLED is not set; exiting", flush=True)
        return

    ssl_ctx = _ssl_context()
    scheme = "wss" if ssl_ctx else "ws"
    print(
        f"[input] listening on {scheme}://0.0.0.0:{INPUT_PORT} (player {PLAYER_ID})",
        flush=True,
    )
    async with websockets.serve(handle_client, "0.0.0.0", INPUT_PORT, ssl=ssl_ctx):
        await asyncio.Future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
