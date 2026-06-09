#!/usr/bin/env python3
"""WebRTC media server: Xvfb video + Pulse audio over UDP, WSS signaling."""

import asyncio
import json
import os
import ssl
import sys
import threading
from pathlib import Path

import gi

gi.require_version("Gst", "1.0")
gi.require_version("GstWebRTC", "1.0")
gi.require_version("GstSdp", "1.0")
from gi.repository import GLib, Gst, GstSdp, GstWebRTC  # noqa: E402

try:
    import websockets
except ImportError:
    print("[webrtc] python-websockets is required", file=sys.stderr)
    sys.exit(1)

SIGNAL_PORT = int(os.environ.get("WEBRTC_SIGNAL_PORT", "6090"))
TLS_CERT = os.environ.get("TLS_CERT", "/opt/ra2/tls/cert.pem")
TLS_KEY = os.environ.get("TLS_KEY", "/opt/ra2/tls/key.pem")
STUN_URL = os.environ.get("STUN_URL", "stun:stun.l.google.com:19302")
DISPLAY = os.environ.get("DISPLAY", ":1")
VIDEO_FPS = int(os.environ.get("WEBRTC_VIDEO_FPS", "20"))
VIDEO_BITRATE = int(os.environ.get("WEBRTC_VIDEO_BITRATE", "800000"))
UDP_MIN = int(os.environ.get("WEBRTC_UDP_PORT_MIN", "62001"))
UDP_MAX = int(os.environ.get("WEBRTC_UDP_PORT_MAX", "62020"))
PULSE_TCP_PORT = int(os.environ.get("PULSE_TCP_PORT", "4711"))
PLAYER_ID = os.environ.get("PLAYER_ID", "1")

PIPELINE_DESC = f"""
webrtcbin name=sendrecv bundle-policy=max-bundle stun-server={STUN_URL}
 ximagesrc use-damage=false show-pointer=true display-name={DISPLAY} !
 videorate max-rate={VIDEO_FPS} !
 videoconvert ! queue !
 vp8enc deadline=1 target-bitrate={VIDEO_BITRATE} keyframe-max-dist={VIDEO_FPS * 2} !
 rtpvp8pay pt=96 !
 queue ! application/x-rtp,media=video,encoding-name=VP8,payload=96 ! sendrecv.
 tcpclientsrc host=127.0.0.1 port={PULSE_TCP_PORT} do-timestamp=true !
 audio/x-raw,format=S16LE,channels=2,rate=44100,layout=interleaved !
 audioconvert ! audioresample ! queue !
 opusenc bitrate=96000 !
 rtpopuspay pt=97 !
 queue ! application/x-rtp,media=audio,encoding-name=OPUS,payload=97 ! sendrecv.
"""


class WebRTCServer:
    def __init__(self):
        Gst.init(None)
        self.pipeline = Gst.parse_launch(PIPELINE_DESC)
        self.webrtc = self.pipeline.get_by_name("sendrecv")
        self.webrtc.connect("on-negotiation-needed", self._on_negotiation_needed)
        self.webrtc.connect("on-ice-candidate", self._on_ice_candidate)
        self.webrtc.connect("notify::ice-connection-state", self._on_ice_state)
        self._configure_ice_port_range()
        self.clients: set = set()
        self.pending_offer = None
        self.loop = GLib.MainLoop()
        self.async_loop = None
        self.pipeline.set_state(Gst.State.PLAYING)

    def _configure_ice_port_range(self):
        try:
            ice = self.webrtc.get_property("ice-agent")
            if ice is not None:
                ice.set_property("min-rtp-port", UDP_MIN)
                ice.set_property("max-rtp-port", UDP_MAX)
                print(f"[webrtc] ICE UDP range {UDP_MIN}-{UDP_MAX}", flush=True)
        except Exception as exc:
            print(f"[webrtc] ICE port range not configured: {exc}", flush=True)

    def _on_ice_state(self, _element, _pspec):
        state = self.webrtc.get_property("ice-connection-state")
        print(f"[webrtc] ICE state: {state}", flush=True)

    def _on_negotiation_needed(self, element):
        promise = Gst.Promise.new_with_change_func(self._on_offer_created, element, None)
        element.emit("create-offer", None, promise)

    def _on_offer_created(self, promise, _webrtc, _user_data):
        reply = promise.get_reply()
        offer = reply.get_value("offer")
        promise = Gst.Promise.new()
        self.webrtc.emit("set-local-description", offer, promise)
        promise.interrupt()
        self.pending_offer = {"type": "offer", "sdp": offer.sdp.as_text()}
        if self.async_loop:
            asyncio.run_coroutine_threadsafe(self._broadcast_offer(), self.async_loop)

    async def _broadcast_offer(self):
        if not self.pending_offer:
            return
        message = json.dumps(self.pending_offer)
        dead = set()
        for ws in self.clients:
            try:
                await ws.send(message)
            except Exception:
                dead.add(ws)
        self.clients -= dead

    def _on_ice_candidate(self, _element, mlineindex, candidate):
        payload = json.dumps(
            {"type": "ice", "candidate": candidate, "sdpMLineIndex": mlineindex}
        )
        if self.async_loop:
            asyncio.run_coroutine_threadsafe(self._send_ice(payload), self.async_loop)

    async def _send_ice(self, payload):
        dead = set()
        for ws in self.clients:
            try:
                await ws.send(payload)
            except Exception:
                dead.add(ws)
        self.clients -= dead

    async def handle_client(self, websocket):
        self.clients.add(websocket)
        print(f"[webrtc] client connected (player {PLAYER_ID})", flush=True)
        if self.pending_offer:
            await websocket.send(json.dumps(self.pending_offer))
        try:
            async for raw in websocket:
                await self._handle_message(raw)
        finally:
            self.clients.discard(websocket)
            print(f"[webrtc] client disconnected (player {PLAYER_ID})", flush=True)

    async def _handle_message(self, raw):
        data = json.loads(raw)
        msg_type = data.get("type")
        if msg_type == "answer":
            _, sdp = GstSdp.SDPMessage.new()
            if (
                GstSdp.sdp_message_parse_buffer(bytes(data["sdp"].encode()), sdp)
                != GstSdp.SDPResult.OK
            ):
                print("[webrtc] failed to parse remote answer SDP", flush=True)
                return
            answer = GstWebRTC.WebRTCSessionDescription.new(
                GstWebRTC.WebRTCSDPType.ANSWER, sdp
            )
            promise = Gst.Promise.new()
            self.webrtc.emit("set-remote-description", answer, promise)
            promise.interrupt()
            print("[webrtc] remote answer applied", flush=True)
        elif msg_type == "ice":
            self.webrtc.emit(
                "add-ice-candidate", data.get("sdpMLineIndex", 0), data.get("candidate", "")
            )

    def run_glib(self):
        self.loop.run()

    def set_async_loop(self, loop):
        self.async_loop = loop


def _ssl_context():
    if not (Path(TLS_CERT).is_file() and Path(TLS_KEY).is_file()):
        return None
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(TLS_CERT, TLS_KEY)
    return ctx


async def main_async(server: WebRTCServer):
    server.set_async_loop(asyncio.get_running_loop())
    ssl_ctx = _ssl_context()
    scheme = "wss" if ssl_ctx else "ws"
    print(
        f"[webrtc] signaling on {scheme}://0.0.0.0:{SIGNAL_PORT} "
        f"(player {PLAYER_ID}, STUN {STUN_URL})",
        flush=True,
    )

    async def handler(websocket):
        await server.handle_client(websocket)

    async with websockets.serve(handler, "0.0.0.0", SIGNAL_PORT, ssl=ssl_ctx):
        await asyncio.Future()


def main():
    if os.environ.get("WEBRTC_ENABLED", "0") != "1":
        print("[webrtc] WEBRTC_ENABLED is not set; exiting", flush=True)
        sys.exit(0)

    server = WebRTCServer()
    threading.Thread(target=server.run_glib, daemon=True).start()
    try:
        asyncio.run(main_async(server))
    except KeyboardInterrupt:
        pass
    finally:
        server.pipeline.set_state(Gst.State.NULL)


if __name__ == "__main__":
    main()
