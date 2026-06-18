#!/usr/bin/env python3
import asyncio
import base64
import contextlib
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
_RESOLVED_PUBLIC_ICE_HOST: Optional[str] = None


def _sdp_mline_mids(sdp: str) -> list[str]:
    mids: list[str] = []
    for line in sdp.splitlines():
        clean = line.strip()
        if clean.startswith("a=mid:"):
            mids.append(clean[6:])
    return mids


def _looks_like_ip(value: str) -> bool:
    try:
        socket.inet_pton(socket.AF_INET, value)
        return True
    except OSError:
        pass
    try:
        socket.inet_pton(socket.AF_INET6, value)
        return True
    except OSError:
        return False


def _public_ice_host() -> str:
    global _RESOLVED_PUBLIC_ICE_HOST
    if _RESOLVED_PUBLIC_ICE_HOST is not None:
        return _RESOLVED_PUBLIC_ICE_HOST
    if ICE_CANDIDATE_HOST:
        host = ICE_CANDIDATE_HOST
    elif NAS_PUBLIC_HOSTNAME:
        host = NAS_PUBLIC_HOSTNAME
    else:
        _RESOLVED_PUBLIC_ICE_HOST = NAS_LAN_IP
        return _RESOLVED_PUBLIC_ICE_HOST
    if not host or _looks_like_ip(host):
        _RESOLVED_PUBLIC_ICE_HOST = host
        return _RESOLVED_PUBLIC_ICE_HOST
    try:
        resolved = socket.gethostbyname(host)
        print(f"[webrtc] resolved ICE host {host} -> {resolved}", flush=True)
        _RESOLVED_PUBLIC_ICE_HOST = resolved
        return resolved
    except OSError as exc:
        print(f"[webrtc] could not resolve ICE host {host}: {exc}", flush=True)
        _RESOLVED_PUBLIC_ICE_HOST = host
        return host


def _ice_advertise_hosts(address: str) -> list[str]:
    """LAN + public addresses so ICE works on the same subnet and over DDNS."""
    hosts: list[str] = []
    if NAS_LAN_IP:
        hosts.append(NAS_LAN_IP)
    public = _public_ice_host()
    if public and public not in hosts:
        hosts.append(public)
    if not hosts:
        hosts.append(address)
    return hosts


def _replace_candidate_host(candidate: str, new_host: str) -> str:
    parts = candidate.split()
    if len(parts) < 6:
        return candidate
    if parts[4] == new_host:
        return candidate
    rewritten = parts[:]
    rewritten[4] = new_host
    return " ".join(rewritten)


def _expand_ice_candidates(candidate: str) -> list[str]:
    """Duplicate private/Docker candidates for LAN IP and public DDNS IP."""
    if not candidate:
        return [candidate]
    parts = candidate.split()
    if len(parts) < 6:
        return [candidate]
    address = parts[4]
    public = _public_ice_host()
    known = {h for h in (NAS_LAN_IP, public, NAS_PUBLIC_HOSTNAME, ICE_CANDIDATE_HOST) if h}
    if address in known or address.startswith(("172.", "10.", "192.168.")):
        targets = _ice_advertise_hosts(address)
        if address not in known and address.startswith(("172.", "10.", "192.168.")):
            port = parts[5] if len(parts) > 5 else "?"
            proto = parts[2] if len(parts) > 2 else "?"
            print(
                f"[webrtc] expand ICE {address} -> {targets} port {port} ({proto})",
                flush=True,
            )
        out: list[str] = []
        seen: set[str] = set()
        for host in targets:
            rewritten = _replace_candidate_host(candidate, host)
            if rewritten not in seen:
                seen.add(rewritten)
                out.append(rewritten)
        return out or [candidate]
    return [candidate]


def _rewrite_sdp_ice_candidates(sdp: str) -> str:
    lines = sdp.splitlines()
    out: list[str] = []
    for line in lines:
        stripped = line.strip()
        if not stripped.startswith("a=candidate:"):
            out.append(line)
            continue
        cand = stripped[len("a=candidate:") :]
        prefix = line[: len(line) - len(stripped)] if stripped else ""
        for expanded in _expand_ice_candidates(cand):
            out.append(f"{prefix}a=candidate:{expanded}")
    ending = "\r\n" if "\r\n" in sdp else "\n"
    body = ending.join(out)
    if sdp.endswith(ending):
        body += ending
    return body


def _sanitize_client_answer_sdp(sdp: str) -> str:
    """Drop mDNS host candidates the GStreamer side cannot resolve."""
    lines: list[str] = []
    dropped = 0
    for line in sdp.splitlines():
        stripped = line.strip()
        if stripped.startswith("a=candidate:") and ".local" in stripped:
            dropped += 1
            continue
        lines.append(line)
    if dropped:
        print(f"[webrtc] stripped {dropped} mDNS candidate(s) from client answer SDP", flush=True)
    ending = "\r\n" if "\r\n" in sdp else "\n"
    body = ending.join(lines)
    if sdp.endswith(ending):
        body += ending
    return body


def _ssl_context():
    if os.environ.get("WEBRTC_SIGNAL_TLS", "0") != "1":
        return None
    if not (Path(TLS_CERT).is_file() and Path(TLS_KEY).is_file()):
        return None
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(TLS_CERT, TLS_KEY)
    return ctx


def _summarize_sdp_ice(sdp: str) -> dict:
    from collections import Counter

    types: Counter[str] = Counter()
    protos: Counter[str] = Counter()
    for raw in sdp.splitlines():
        line = raw.strip()
        if not line.startswith("a=candidate:"):
            continue
        toks = line[len("a=candidate:") :].split()
        if len(toks) >= 3:
            protos[toks[2].lower()] += 1
        if "typ" in toks:
            idx = toks.index("typ")
            if idx + 1 < len(toks):
                types[toks[idx + 1].lower()] += 1
    return {
        "candidates": sum(types.values()),
        "types": dict(types),
        "protocols": dict(protos),
        "hasIceLite": "a=ice-lite" in sdp,
    }


def _sdp_ice_has_usable_candidates(summary: dict) -> bool:
    types = summary.get("types") or {}
    return bool(types.get("srflx") or types.get("relay") or types.get("host"))


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
        self._helper_shutdown_task: Optional[asyncio.Task] = None
        self._lock = asyncio.Lock()
        self.client_useful_ice = 0
        self.sdp_mids: list[str] = []
        self.last_answer_ice: dict = {}
        self.server_ice_payloads: list[dict] = []
        self.remote_answer_received = False
        self.client_connected_at: Optional[float] = None

    NEGOTIATION_GRACE_SEC = 45.0

    async def _cancel_helper_shutdown(self) -> None:
        if not self._helper_shutdown_task:
            return
        self._helper_shutdown_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await self._helper_shutdown_task
        self._helper_shutdown_task = None

    async def _delayed_helper_shutdown(self, delay: float, reason: str) -> None:
        try:
            await asyncio.sleep(delay)
        except asyncio.CancelledError:
            return
        if not self.clients:
            print(f"[webrtc] signaling idle for {delay:.0f}s; stopping helper", flush=True)
            await self._stop_helper(reason)

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

    async def ensure_helper(self, *, reuse: bool = False) -> None:
        async with self._lock:
            if (
                reuse
                and self.helper
                and self.helper.poll() is None
                and self.pending_offer
            ):
                return
            if self.helper and self.helper.poll() is None:
                await self._stop_helper("fresh_client_session")
            elif self.helper:
                await self._stop_helper("fresh_client_session")
            self.offer_event.clear()
            self.pending_offer = None
            self.server_ice_payloads = []
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

    def _sdp_mid_for_mline(self, mline: int) -> str:
        if self.sdp_mids and 0 <= mline < len(self.sdp_mids):
            return self.sdp_mids[mline]
        return str(mline)

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
                sdp = _rewrite_sdp_ice_candidates(sdp)
                self.pending_offer = sdp
                self.sdp_mids = _sdp_mline_mids(sdp)
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
            elif parts[0] == "ICE" and len(parts) >= 2:
                mline = int(parts[1])
                candidate = ""
                if len(parts) == 3:
                    candidate = base64.b64decode(parts[2]).decode("utf-8", errors="replace")
                if not candidate:
                    print(f"[webrtc] end-of-candidates from helper mline={mline}", flush=True)
                    await self._broadcast(
                        {
                            "type": "ice",
                            "candidate": "",
                            "sdpMid": self._sdp_mid_for_mline(mline),
                            "sdpMLineIndex": mline,
                            "complete": True,
                        }
                    )
                    continue
                for expanded in _expand_ice_candidates(candidate):
                    payload = {
                        "type": "ice",
                        "candidate": expanded,
                        "sdpMid": self._sdp_mid_for_mline(mline),
                        "sdpMLineIndex": mline,
                    }
                    self.server_ice_payloads.append(payload)
                    await self._broadcast(payload)
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
        await self._cancel_helper_shutdown()
        loop = asyncio.get_running_loop()
        now = loop.time()
        reuse_helper = False
        if self.clients:
            # A new connection supersedes any stale/zombie client. The browser
            # guards against opening duplicate sockets (signalingSocketBusy), so
            # this only fires for a genuine takeover or a dead half-open socket —
            # it must never let one stuck client permanently hold the slot.
            print(
                f"[webrtc] rejecting extra client (another client is already connected); "
                f"replacing stale signaling client ({len(self.clients)} active)",
                flush=True,
            )
            for old in list(self.clients):
                self.clients.discard(old)
                with contextlib.suppress(Exception):
                    await old.close(code=4000, reason="replaced by new client")
            # Reuse the live helper + already-gathered offer for fast reconnects
            # so we don't thrash the encoder pipeline on every takeover.
            reuse_helper = bool(
                self.helper and self.helper.poll() is None and self.pending_offer
            )
        self.clients.add(websocket)
        self._touch_session()
        self.client_connected_at = now
        self.remote_answer_received = False
        self.client_useful_ice = 0
        if not reuse_helper:
            self.sdp_mids = []
        self.last_answer_ice = {}
        print(
            f"[webrtc] client connected ({len(self.clients)} active, reuse_helper={reuse_helper})",
            flush=True,
        )
        try:
            await self.ensure_helper(reuse=reuse_helper)
            try:
                await asyncio.wait_for(self.offer_event.wait(), timeout=OFFER_WAIT_SECONDS)
            except asyncio.TimeoutError:
                print("[webrtc] timed out waiting for SDP offer", flush=True)
            if self.pending_offer:
                await websocket.send(json.dumps({"type": "offer", "sdp": self.pending_offer}))
                print("[webrtc] offer sent to client", flush=True)
                if self.server_ice_payloads:
                    print(
                        f"[webrtc] replaying {len(self.server_ice_payloads)} cached server ICE candidate(s)",
                        flush=True,
                    )
                    for payload in self.server_ice_payloads:
                        await websocket.send(json.dumps(payload))
            async for message in websocket:
                self._touch_session()
                await self._handle_message(message)
        except Exception as exc:
            print(f"[webrtc] client handler error: {exc}", flush=True)
        finally:
            self.clients.discard(websocket)
            print(f"[webrtc] client disconnected ({len(self.clients)} active)", flush=True)
            if not self.clients:
                self.client_connected_at = None
                self.remote_answer_received = False
                await self._cancel_helper_shutdown()
                loop = asyncio.get_running_loop()
                self.idle_deadline = loop.time() + IDLE_SHUTDOWN_SECONDS
                self._helper_shutdown_task = asyncio.create_task(
                    self._delayed_helper_shutdown(IDLE_SHUTDOWN_SECONDS, "signaling_idle")
                )

    async def _handle_message(self, message: str) -> None:
        data = json.loads(message)
        message_type = data.get("type")
        if message_type:
            print(f"[webrtc] message from client: {message_type}", flush=True)
        if data.get("type") == "answer" and self.helper and self.helper.stdin:
            sdp = _sanitize_client_answer_sdp(data.get("sdp", ""))
            encoded = base64.b64encode(sdp.encode("utf-8")).decode("ascii")
            self.helper.stdin.write(f"ANSWER {encoded}\n")
            self.helper.stdin.flush()
            self.remote_answer_received = True
            self.last_answer_ice = _summarize_sdp_ice(sdp)
            print(
                f"[webrtc] remote answer applied ({len(sdp)} bytes, ICE: {json.dumps(self.last_answer_ice, sort_keys=True)})",
                flush=True,
            )
            return
        if data.get("type") == "ice" and self.helper and self.helper.stdin:
            candidate = data.get("candidate") or ""
            mline = int(data.get("sdpMLineIndex", 0))
            if not candidate:
                print(
                    f"[webrtc] end-of-candidates from client mline={mline} "
                    f"(useful={self.client_useful_ice})",
                    flush=True,
                )
                if self.client_useful_ice == 0:
                    if _sdp_ice_has_usable_candidates(self.last_answer_ice):
                        print(
                            "[webrtc] note: trickle had no srflx/relay, but answer SDP already "
                            f"contains usable ICE: {json.dumps(self.last_answer_ice.get('types', {}))}",
                            flush=True,
                        )
                    else:
                        print(
                            "[webrtc] WARN: no usable client ICE in trickle or answer SDP "
                            "(need srflx/relay in answer, not mDNS .local in trickle)",
                            flush=True,
                        )
                        print(
                            "[webrtc] HINT: run play page with ?relayOnly=1 from a remote network "
                            "and check browser icecandidateerror / answer ICE relay count",
                            flush=True,
                        )
                self.helper.stdin.write(f"ICE {mline} \n")
                self.helper.stdin.flush()
                return
            if ".local" in candidate and " typ host " in f" {candidate} ":
                print(f"[webrtc] ignoring client mDNS ICE: {candidate[:80]}", flush=True)
                return
            parts = candidate.split()
            addr = parts[4] if len(parts) > 4 else "?"
            port = parts[5] if len(parts) > 5 else "?"
            proto = parts[2] if len(parts) > 2 else "?"
            typ = parts[7] if len(parts) > 7 else "?"
            self.client_useful_ice += 1
            print(
                f"[webrtc] client ICE mline={mline} {proto} {addr}:{port} typ={typ}",
                flush=True,
            )
            encoded = base64.b64encode(candidate.encode("utf-8")).decode("ascii")
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
