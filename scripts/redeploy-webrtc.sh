#!/bin/sh
set -eu

HOST="${NAS_HOST:-MediaServer2Local}"
TARGET="${NAS_TARGET:-/volume2/Data/App_Development/ra2-lan-party/project}"
SERVICE="${RA2_WEBRTC_SERVICE:-ra2-player-1}"
SIGNAL_PORT="${PLAYER1_WEBRTC_SIGNAL_PORT:-6083}"
NAS_LAN_IP="${NAS_LAN_IP:-192.168.0.193}"
BUILD_ON_NAS="${RA2_WEBRTC_BUILD:-0}"
EXPECTED_CODEC="${WEBRTC_VIDEO_CODEC:-}"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

echo "[redeploy-webrtc] syncing project to ${HOST}:${TARGET}"
NAS_HOST="$HOST" NAS_TARGET="$TARGET" sh "$SCRIPT_DIR/sync-to-nas.sh"

if [ "$BUILD_ON_NAS" = "1" ]; then
  echo "[redeploy-webrtc] rebuilding on NAS and recreating ${SERVICE}"
  compose_action="up -d --build --force-recreate"
else
  echo "[redeploy-webrtc] recreating ${SERVICE} without rebuilding (RA2_WEBRTC_BUILD=1 to build)"
  compose_action="up -d --no-build --force-recreate"
fi
ssh "$HOST" "cd '$TARGET' && RA2_COMPOSE_WEBRTC=1 sh -c '. ./scripts/lib.sh; run_compose .env ${compose_action} ${SERVICE}'"

echo "[redeploy-webrtc] verifying helper, encoder plugins, and remote page symlinks"
ssh "$HOST" "cd '$TARGET' && sh -c '. ./scripts/lib.sh; run_docker exec ${SERVICE} sh -lc '\\''
  set -eu
  test -x /opt/ra2/webrtc-media-helper || { echo \"compiled helper missing\"; exit 1; }
  helper_count=\$(pgrep -fc \"^/opt/ra2/webrtc-media-helper\" || true)
  if [ \"\$helper_count\" -gt 1 ]; then
    echo \"expected one helper, found \$helper_count\"
    pgrep -af webrtc-media-helper
    exit 1
  fi
  gst-inspect-1.0 vp8enc >/dev/null 2>&1 || { echo \"vp8enc missing\"; exit 1; }
  gst-inspect-1.0 x264enc >/dev/null 2>&1 || echo \"x264enc missing (H264 fallback unavailable)\"
  gst-inspect-1.0 vah264enc >/dev/null 2>&1 || echo \"vah264enc missing (hardware H264 unavailable)\"
  gst-inspect-1.0 vah265enc >/dev/null 2>&1 || echo \"vah265enc missing (hardware HEVC unavailable)\"
  test -L /opt/novnc/remote.html
  test -L /opt/novnc/remote-play.js
  env | grep -E \"^WEBRTC_VIDEO_|^WEBRTC_LATENCY_PRESET=\"
'\\'''"

echo "[redeploy-webrtc] checking signaling SDP codec from ${NAS_LAN_IP}:${SIGNAL_PORT}"
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

async def main():
    url = "ws://${NAS_LAN_IP}:${SIGNAL_PORT}"
    async with websockets.connect(url, open_timeout=5) as ws:
        msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=35))
        sdp = msg.get("sdp", "")
        codecs = [name for name, marker in CODEC_MARKERS.items() if marker in sdp]
        print(f"signal={url} codecs={','.join(codecs) or 'none'} sdp_len={len(sdp)}")
        expected_marker = CODEC_MARKERS.get(EXPECTED_CODEC)
        if expected_marker and expected_marker not in sdp:
            raise SystemExit(f"expected {EXPECTED_CODEC} in SDP offer")
        if not expected_marker and not codecs:
            raise SystemExit("expected a supported video codec in SDP offer")

asyncio.run(main())
PY

echo "[redeploy-webrtc] complete"
