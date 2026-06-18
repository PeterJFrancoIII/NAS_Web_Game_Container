#!/bin/sh
# Verify WebRTC signaling delivers an SDP offer (run from Mac, VPN optional).
set -eu

DDNS="${NAS_PUBLIC_HOSTNAME:-peterjfrancoiii2.synology.me}"
PLAY_PORT="${PLAYER1_HTTP_PORT:-6081}"

python3 - "$DDNS" "$PLAY_PORT" <<'PY'
import json
import ssl
import sys
import websocket  # pip install websocket-client

host, port = sys.argv[1], sys.argv[2]
url = f"wss://{host}:{port}/webrtc-signal"
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
print(f"[signaling-probe] connecting {url}")
ws = websocket.create_connection(url, sslopt={"context": ctx}, timeout=15)
msg = json.loads(ws.recv())
ws.close()
if msg.get("type") != "offer" or not msg.get("sdp"):
    print(f"[signaling-probe] FAIL unexpected message: {msg!r}", file=sys.stderr)
    sys.exit(1)
ice = sum(1 for line in msg["sdp"].splitlines() if line.startswith("a=candidate:"))
print(f"[signaling-probe] OK offer {len(msg['sdp'])} bytes, {ice} ICE candidates")
PY
