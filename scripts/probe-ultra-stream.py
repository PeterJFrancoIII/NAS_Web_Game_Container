#!/usr/bin/env python3
"""Probe an ultra stream gateway: request settings, report ready/fallbacks/frames.

Usage:
  probe-ultra-stream.py wss://host:6081/stream '{"videoCodec":"H265"}' [seconds]

Connects, sends a start message with the given settings, then counts video
frames and keyframes for a few seconds. Prints a JSON summary for scripting.
"""

import asyncio
import json
import ssl
import sys

import websockets


async def probe(url: str, settings: dict, seconds: float) -> dict:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    summary: dict = {
        "url": url,
        "requestedSettings": settings,
        "video_frames": 0,
        "keyframes": 0,
        "video_bytes_b64": 0,
        "audio_packets": 0,
    }
    async with websockets.connect(url, ssl=ctx, max_size=16 * 1024 * 1024) as ws:
        await ws.send(json.dumps({"type": "start", "settings": settings}))
        loop = asyncio.get_event_loop()
        deadline = loop.time() + seconds
        while loop.time() < deadline:
            try:
                raw = await asyncio.wait_for(ws.recv(), timeout=max(0.1, deadline - loop.time()))
            except asyncio.TimeoutError:
                break
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                continue
            kind = msg.get("type")
            if kind == "ready":
                summary["ready"] = {
                    "width": msg.get("width"),
                    "height": msg.get("height"),
                    "active": msg.get("active"),
                    "fallbacks": msg.get("fallbacks"),
                    "transport": msg.get("transport"),
                    "availableVideoCodec": (msg.get("available") or {}).get("videoCodec"),
                    "availableVideoResolution": (msg.get("available") or {}).get("videoResolution"),
                }
            elif kind == "video":
                summary["video_frames"] += 1
                summary["video_bytes_b64"] += len(msg.get("data", ""))
                if msg.get("key"):
                    summary["keyframes"] += 1
            elif kind == "audio":
                summary["audio_packets"] += 1
    return summary


def main() -> None:
    url = sys.argv[1]
    settings = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
    seconds = float(sys.argv[3]) if len(sys.argv) > 3 else 6.0
    summary = asyncio.run(probe(url, settings, seconds))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
