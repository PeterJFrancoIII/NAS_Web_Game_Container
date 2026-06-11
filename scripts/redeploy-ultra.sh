#!/bin/sh
# Ultra-light Arch browser streaming profile (single-port WSS/WebCodecs).
set -eu

HOST="${NAS_HOST:-MediaServer2}"
TARGET="${NAS_TARGET:-/volume2/Data/App_Development/ra2-lan-party/project}"
SERVICE="${RA2_ULTRA_SERVICE:-ra2-player-1}"
HTTP_PORT="${PLAYER1_HTTP_PORT:-6081}"
NAS_LAN_IP="${NAS_LAN_IP:-192.168.0.193}"
BUILD_ON_NAS="${RA2_ULTRA_BUILD:-1}"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

echo "[redeploy-ultra] syncing project to ${HOST}:${TARGET}"
NAS_HOST="$HOST" NAS_TARGET="$TARGET" sh "$SCRIPT_DIR/sync-to-nas.sh"

if [ "$BUILD_ON_NAS" = "1" ]; then
  echo "[redeploy-ultra] building ultra image and recreating ${SERVICE}"
  compose_action="up -d --build --force-recreate"
else
  echo "[redeploy-ultra] recreating ${SERVICE} without rebuild (RA2_ULTRA_BUILD=1 to build)"
  compose_action="up -d --no-build --force-recreate"
fi

ssh "$HOST" "cd '$TARGET' && RA2_COMPOSE_ULTRA=1 sh -c '. ./scripts/lib.sh; run_compose .env ${compose_action} ${SERVICE}'"

echo "[redeploy-ultra] verifying ultra gateway and stream helper"
ssh "$HOST" "cd '$TARGET' && sh -c '. ./scripts/lib.sh; run_docker exec ${SERVICE} sh -lc '\\''
  set -eu
  test -x /opt/ra2/stream-helper || { echo \"stream-helper missing\"; exit 1; }
  pgrep -f ra2-stream-gateway.py >/dev/null || { echo \"gateway not running\"; exit 1; }
  pgrep -f \"Xvfb :1\" >/dev/null || { echo \"Xvfb missing\"; exit 1; }
  ! pgrep -f websockify >/dev/null || { echo \"websockify should be disabled in ultra mode\"; exit 1; }
  ! pgrep -f x11vnc >/dev/null || { echo \"x11vnc should be disabled in ultra mode\"; exit 1; }
  env | grep -E \"^ULTRA_VIDEO_|^ULTRA_GATEWAY_\"
'\\'''"

echo "[redeploy-ultra] browser URL: https://${NAS_LAN_IP}:${HTTP_PORT}/"
echo "[redeploy-ultra] complete"
