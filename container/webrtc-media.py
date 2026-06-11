#!/usr/bin/env python3
import asyncio
import base64
import json
import os
import signal
import ssl
import socket
import subprocess
import sys
from pathlib import Path
from typing import Optional

import websockets
from websockets.server import WebSocketServerProtocol

SIGNAL_PORT = int(os.environ.get("WEBRTC_SIGNAL_PORT", "6090"))
TLS_CERT = os.environ.get("TLS_CERT", "/opt/ra2/tls/cert.pem")
TLS_KEY = os.environ.get("TLS_KEY", "/opt/ra2/tls/key.pem")
HELPER = os.environ.get("WEBRTC_MEDIA_HELPER", "/opt/ra2/webrtc-media-helper")
SESSION_MAX_SECONDS = int(os.environ.get("WEBRTC_SESSION_MAX_SECONDS", "3600"))
IDLE_SHUTDOWN_SECONDS = int(os.environ.get("WEBRTC_IDLE_SHUTDOWN_SECONDS", "60"))
OFFER_WAIT_SECONDS = int(os.environ.get("WEBRTC_OFFER_WAIT_SECONDS", "20"))
NAS_LAN_IP = os.environ.get("NAS_LAN_IP", "").strip()
NAS_PUBLIC_HOSTNAME = os.environ.get("NAS_PUBLIC_HOSTNAME", "").strip()
ICE_CANDIDATE_HOST = os.environ.get("WEBRTC_ICE_CANDIDATE_HOST", "").strip()


def _public_ice_host() -> str:
    if ICE_CANDIDATE_HOST:
        return ICE_CANDIDATE_HOST
    if NAS_PUBLIC_HOSTNAME:
        try:
            return socket.gethostbyname(NAS_PUBLIC_HOSTNAME)
        except OSError as exc:
            print(f"[webrtc] could not resolve NAS_PUBLIC_HOSTNAME={NAS_PUBLIC_HOSTNAME}: {exc}", flush=True)
    return NAS_LAN_IP


def _rewrite_ice_candidate(candidate: str) -> str:
    """Replace Docker-internal host candidates with the address browsers can reach."""
    target_host = _public_ice_host()
    if not candidate or not target_host:
        return candidate
    parts = candidate.split()
    if len(parts) < 6:
        return candidate
    address = parts[4]
    if address in {target_host, NAS_LAN_IP, NAS_PUBLIC_HOSTNAME}:
        return candidate
    if address.startswith("172.") or address.startswith("10.") or address.startswith("192.168."):
        rewritten = parts[:]
        rewritten[4] = target_host
        new_candidate = " ".join(rewritten)
        port = parts[5] if len(parts) > 5 else "?"
        proto = parts[2] if len(parts) > 2 else "?"
        print(
            f"[webrtc] rewrote ICE host {address} -> {target_host} port {port} ({proto})",
            flush=True,
        )
        return new_candidate
    return candidate


def _ssl_context():
    if os.environ.get("WEBRTC_SIGNAL_TLS", "0") != "1":
        return None
    if not (Path(TLS_CERT).is_file() and Path(TLS_KEY).is_file()):
        return None
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(TLS_CERT, TLS_KEY)
    return ctx


class WebRtcBridge:
    def __init__(self) -> None:
        self.clients: set[WebSocketServerProtocol] = set()
        self.helper: Optional[subprocess.Popen[str]] = None
        self.helper_reader: Optional[asyncio.Task] = None
        self.pending_offer: Optional[str] = None
        self.offer_event = asyncio.Event()
        self.session_deadline: Optional[float] = None
        self.idle_deadline: Optional[float] = None
        self._helper_start_monotonic: Optional[float] = None
        self._lock = asyncio.Lock()

    async def _broadcast(self, payload: dict) -> None:
        if not self.clients:
            return
        message = json.dumps(payload)
        await asyncio.gather(
            *[client.send(message) for client in list(self.clients)],
            return_exceptions=True,
        )

    async def _stop_helper(self, reason: str = "unspecified") -> None:
        helper_pid = self.helper.pid if self.helper else None
        print(
            f"[webrtc] stopping helper pid={helper_pid} reason={reason}",
            flush=True,
        )
        current_task = asyncio.current_task()
        if self.helper_reader and self.helper_reader is not current_task:
            self.helper_reader.cancel()
            try:
                await self.helper_reader
            except asyncio.CancelledError:
                pass
            self.helper_reader = None
        if self.helper and self.helper.poll() is None:
            self.helper.terminate()
            try:
                await asyncio.to_thread(self.helper.wait, 3)
            except Exception:
                self.helper.kill()
        self.helper = None
        self.pending_offer = None
        self.offer_event.clear()
        self._helper_start_monotonic = None
        await self._stop_stale_helper_children()

    async def _stop_stale_helper_children(self) -> None:
        """Clean up helper children left behind by interrupted reconnects."""
        helper_name = Path(HELPER).name
        if not helper_name:
            return
        pid = os.getpid()
        await asyncio.to_thread(
            subprocess.run,
            ["pkill", "-TERM", "-P", str(pid), "-f", helper_name],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        await asyncio.sleep(0.2)
        await asyncio.to_thread(
            subprocess.run,
            ["pkill", "-KILL", "-P", str(pid), "-f", helper_name],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )

    async def ensure_helper(self) -> None:
        async with self._lock:
            if self.helper and self.helper.poll() is None:
                return
            await self._stop_helper("ensure_helper_restart")
            self.offer_event.clear()
            self.pending_offer = None
            print("[webrtc] starting media helper", flush=True)
            self.helper = subprocess.Popen(
                [HELPER],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
            )
            helper = self.helper
            self._helper_start_monotonic = asyncio.get_running_loop().time()
            print(f"[webrtc] helper started pid={helper.pid}", flush=True)
            self.helper_reader = asyncio.create_task(self._read_helper_stdout(helper))
            asyncio.create_task(self._read_helper_stderr(helper))

    async def _read_helper_stderr(self, helper: subprocess.Popen[str]) -> None:
        if not helper.stderr:
            return
        while True:
            line = await asyncio.to_thread(helper.stderr.readline)
            if not line:
                break
            line = line.rstrip()
            if line:
                print(f"[webrtc-helper] {line}", flush=True)

    async def _read_helper_stdout(self, helper: subprocess.Popen[str]) -> None:
        if not helper.stdout:
            return
        while True:
            line = await asyncio.to_thread(helper.stdout.readline)
            if not line:
                break
            line = line.strip()
            if not line:
                continue
            parts = line.split(" ", 2)
            if parts[0] == "OFFER" and len(parts) == 2:
                sdp = base64.b64decode(parts[1]).decode("utf-8", errors="replace")
                self.pending_offer = sdp
                self.offer_event.set()
                if self._helper_start_monotonic is not None:
                    elapsed_ms = int(
                        (asyncio.get_running_loop().time() - self._helper_start_monotonic)
                        * 1000
                    )
                    print(
                        f"[webrtc] offer ready in {elapsed_ms}ms ({len(sdp)} bytes)",
                        flush=True,
                    )
                else:
                    print(f"[webrtc] offer ready ({len(sdp)} bytes)", flush=True)
            elif parts[0] == "ICE" and len(parts) == 3:
                candidate = base64.b64decode(parts[2]).decode("utf-8", errors="replace")
                if not candidate:
                    continue
                candidate = _rewrite_ice_candidate(candidate)
                await self._broadcast(
                    {
                        "type": "ice",
                        "candidate": candidate,
                        "sdpMLineIndex": int(parts[1]),
                    }
                )
            else:
                print(f"[webrtc] helper: {line}", flush=True)

        print("[webrtc] helper exited", flush=True)
        if self.helper is helper:
            await self._stop_helper("helper_stdout_eof")

    def _touch_session(self) -> None:
        loop = asyncio.get_running_loop()
        now = loop.time()
        self.session_deadline = now + SESSION_MAX_SECONDS
        self.idle_deadline = now + IDLE_SHUTDOWN_SECONDS

    async def _session_watchdog(self) -> None:
        while True:
            await asyncio.sleep(5)
            if not self.helper or self.helper.poll() is not None:
                continue
            loop = asyncio.get_running_loop()
            now = loop.time()
            if self.session_deadline and now >= self.session_deadline:
                print("[webrtc] session max reached; stopping helper", flush=True)
                await self._stop_helper("session_max")
                continue
            if not self.clients and self.idle_deadline and now >= self.idle_deadline:
                print("[webrtc] idle timeout; stopping helper", flush=True)
                await self._stop_helper("idle_timeout")

    async def handle_client(self, websocket: WebSocketServerProtocol) -> None:
        if self.clients:
            print(
                f"[webrtc] rejecting extra client ({len(self.clients)} active)",
                flush=True,
            )
            await websocket.close(code=4001, reason="another client is already connected")
            return
        self.clients.add(websocket)
        self._touch_session()
        print(f"[webrtc] client connected ({len(self.clients)} active)", flush=True)
        try:
            await self.ensure_helper()
            try:
                await asyncio.wait_for(self.offer_event.wait(), timeout=OFFER_WAIT_SECONDS)
            except asyncio.TimeoutError:
                print("[webrtc] timed out waiting for SDP offer", flush=True)
            if self.pending_offer:
                await websocket.send(json.dumps({"type": "offer", "sdp": self.pending_offer}))
                print("[webrtc] offer sent to client", flush=True)
            async for message in websocket:
                self._touch_session()
                await self._handle_message(message)
        except Exception as exc:
            print(f"[webrtc] client handler error: {exc}", flush=True)
        finally:
            self.clients.discard(websocket)
            print(f"[webrtc] client disconnected ({len(self.clients)} active)", flush=True)
            if not self.clients:
                print("[webrtc] no active clients; stopping helper for clean reconnect", flush=True)
                await self._stop_helper("last_client_disconnected")
                loop = asyncio.get_running_loop()
                self.idle_deadline = loop.time() + IDLE_SHUTDOWN_SECONDS

    async def _handle_message(self, message: str) -> None:
        data = json.loads(message)
        message_type = data.get("type")
        if message_type:
            print(f"[webrtc] message from client: {message_type}", flush=True)
        if data.get("type") == "answer" and self.helper and self.helper.stdin:
            sdp = data.get("sdp", "")
            encoded = base64.b64encode(sdp.encode("utf-8")).decode("ascii")
            self.helper.stdin.write(f"ANSWER {encoded}\n")
            self.helper.stdin.flush()
            print("[webrtc] remote answer applied", flush=True)
            return
        if data.get("type") == "ice" and self.helper and self.helper.stdin:
            candidate = data.get("candidate") or ""
            if not candidate:
                return
            encoded = base64.b64encode(candidate.encode("utf-8")).decode("ascii")
            mline = int(data.get("sdpMLineIndex", 0))
            self.helper.stdin.write(f"ICE {mline} {encoded}\n")
            self.helper.stdin.flush()

    async def run(self) -> None:
        asyncio.create_task(self._session_watchdog())
        ssl_ctx = _ssl_context()
        scheme = "wss" if ssl_ctx else "ws"
        async with websockets.serve(
            self.handle_client,
            "0.0.0.0",
            SIGNAL_PORT,
            ping_interval=20,
            ssl=ssl_ctx,
        ):
            print(f"[webrtc] signaling on {scheme}://0.0.0.0:{SIGNAL_PORT}", flush=True)
            await asyncio.Future()


def main() -> None:
    bridge = WebRtcBridge()

    def _shutdown(*_args: object) -> None:
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)
    try:
        asyncio.run(bridge.run())
    except SystemExit:
        pass


if __name__ == "__main__":
    main()
