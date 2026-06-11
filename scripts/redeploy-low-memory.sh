#!/bin/sh
set -eu

HOST="${NAS_HOST:-MediaServer2Local}"
TARGET="${NAS_TARGET:-/volume2/Data/App_Development/ra2-lan-party/project}"
NAS_LAN_IP="${NAS_LAN_IP:-192.168.0.193}"
SIGNAL1_PORT="${PLAYER1_WEBRTC_SIGNAL_PORT:-6083}"
SIGNAL2_PORT="${PLAYER2_WEBRTC_SIGNAL_PORT:-6084}"
BUILD_ON_NAS="${RA2_LOW_MEMORY_BUILD:-0}"
EXPECTED_CODEC="${WEBRTC_VIDEO_CODEC:-}"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"

echo "[redeploy-low-memory] syncing project to ${HOST}:${TARGET}"
NAS_HOST="$HOST" NAS_TARGET="$TARGET" sh "$SCRIPT_DIR/sync-to-nas.sh"

echo "[redeploy-low-memory] preflight memory check on NAS"
ssh "$HOST" "cd '$TARGET' && RA2_MEMORY_STRICT=0 sh scripts/check-low-latency-host.sh" || true

if [ "$BUILD_ON_NAS" = "1" ]; then
  echo "[redeploy-low-memory] rebuilding on NAS and recreating both players"
  compose_action="up -d --build --force-recreate"
else
  echo "[redeploy-low-memory] recreating both players without rebuilding (RA2_LOW_MEMORY_BUILD=1 to build)"
  compose_action="up -d --no-build --force-recreate"
fi
ssh "$HOST" "cd '$TARGET' && RA2_COMPOSE_WEBRTC=1 sh -c '. ./scripts/lib.sh; run_compose .env ${compose_action} ra2-player-1 ra2-player-2'"

echo "[redeploy-low-memory] waiting for containers to settle"
sleep 25

echo "[redeploy-low-memory] post-deploy memory and process check"
ssh "$HOST" "cd '$TARGET' && sh -c '. ./scripts/lib.sh; run_docker stats --no-stream ra2-player-1 ra2-player-2 2>/dev/null || true; sh scripts/check-low-latency-host.sh'"

verify_player() {
  service="$1"
  signal_port="$2"
  ssh "$HOST" "cd '$TARGET' && sh -c '. ./scripts/lib.sh; run_docker exec ${service} sh -lc '\\''
    set -eu
    pgrep -af webrtc-media.py || true
    game=\$(ps -eo pid,ppid,stat,comm,args 2>/dev/null | awk \"/RA2MD|gamemd/ && !/awk/ {print}\" || true)
    zombie=\$(printf \"%s\\n\" \"\$game\" | awk \"\\\$3 ~ /^Z/ {print}\")
    if [ -n \"\$zombie\" ]; then
      echo \"${service}: game process is defunct\"
      printf \"%s\\n\" \"\$zombie\"
      exit 1
    fi
    if [ -z \"\$game\" ]; then
      echo \"${service}: game process not found yet\"
    else
      echo \"${service}: game process ok\"
      printf \"%s\\n\" \"\$game\"
    fi
    env | grep -E \"^RA2_MEM|^RA2_MEMORY|^WEBRTC_VIDEO|^WEBRTC_OFFER\" || true
    test -x /opt/ra2/webrtc-media-helper || {
      echo \"${service}: missing /opt/ra2/webrtc-media-helper\"
      exit 1
    }
  '\\'''"
}

verify_player ra2-player-1 "$SIGNAL1_PORT"
verify_player ra2-player-2 "$SIGNAL2_PORT"

echo "[redeploy-low-memory] checking WebRTC SDP on ports ${SIGNAL1_PORT} and ${SIGNAL2_PORT}"
python3 - <<PY
import asyncio
import json
import sys

try:
    import websockets
except ImportError:
    print("python websockets package required for SDP verification", file=sys.stderr)
    sys.exit(1)

EXPECTED_CODEC = "${EXPECTED_CODEC}".strip().upper()
CODEC_MARKERS = {
    "H264": "H264/90000",
    "VP8": "VP8/90000",
    "H265": "H265/90000",
    "HEVC": "H265/90000",
}

def offered_codecs(sdp):
    return [name for name, marker in CODEC_MARKERS.items() if marker in sdp]

async def check(port):
    url = f"ws://${NAS_LAN_IP}:{port}"
    try:
        async with websockets.connect(url, open_timeout=5) as ws:
            msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=35))
            sdp = msg.get("sdp", "")
            codecs = offered_codecs(sdp)
            print(f"signal={url} codecs={','.join(codecs) or 'none'} sdp_len={len(sdp)}")
            expected_marker = CODEC_MARKERS.get(EXPECTED_CODEC)
            if expected_marker and expected_marker not in sdp:
                raise SystemExit(f"expected {EXPECTED_CODEC} in SDP offer on {url}")
            if not expected_marker and not codecs:
                raise SystemExit(f"expected a supported video codec in SDP offer on {url}")
    except Exception as exc:
        print(f"signal={url} probe_note={type(exc).__name__}: {exc}")
        print("(another browser tab may already hold the signaling session)")

async def main():
    await check(${SIGNAL1_PORT})
    await check(${SIGNAL2_PORT})

asyncio.run(main())
PY

echo "[redeploy-low-memory] complete"
