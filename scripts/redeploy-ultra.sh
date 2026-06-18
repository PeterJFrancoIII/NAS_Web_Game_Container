#!/bin/sh
# Ultra-light Arch browser streaming profile (single-port WSS/WebCodecs).
set -eu

HOST="${NAS_HOST:-MediaServer2Local}"
TARGET="${NAS_TARGET:-/volume2/Data/App_Development/ra2-lan-party/project}"
SERVICES="${RA2_ULTRA_SERVICE:-ra2-player-1 ra2-player-2}"
NAS_LAN_IP="${NAS_LAN_IP:-192.168.0.193}"
BUILD_ON_NAS="${RA2_ULTRA_BUILD:-1}"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"

player_http_port() {
  case "$1" in
    ra2-player-2) printf '%s\n' "${PLAYER2_HTTP_PORT:-6082}" ;;
    ra2-player-dev) printf '%s\n' "${DEV_RAM_HTTP_PORT:-6091}" ;;
    *) printf '%s\n' "${PLAYER1_HTTP_PORT:-6081}" ;;
  esac
}

player_container() {
  case "$1" in
    ra2-player-2) printf '%s\n' "${PLAYER2_CONTAINER:-Cloud_Gaming_Player2}" ;;
    ra2-player-dev) printf '%s\n' "${RA2_RAM_SERVICE:-ra2-player-dev}" ;;
    *) printf '%s\n' "${PLAYER1_CONTAINER:-Cloud_Gaming_Player1}" ;;
  esac
}

echo "[redeploy-ultra] running deploy test gate (WebRTC + full unit suite)"
sh "$SCRIPT_DIR/run-deploy-tests.sh"

echo "[redeploy-ultra] syncing project to ${HOST}:${TARGET}"
NAS_HOST="$HOST" NAS_TARGET="$TARGET" sh "$SCRIPT_DIR/sync-to-nas.sh"

if [ "$BUILD_ON_NAS" = "1" ]; then
  echo "[redeploy-ultra] building ultra image and recreating ${SERVICES}"
  compose_action="up -d --build --force-recreate"
else
  echo "[redeploy-ultra] recreating ${SERVICES} without rebuild (RA2_ULTRA_BUILD=1 to build)"
  compose_action="up -d --no-build --force-recreate"
fi

ssh "$HOST" "sudo sh -c 'cd '\''$TARGET'\'' && RA2_COMPOSE_ULTRA=1 RA2_COMPOSE_ULTRA_UDP=1 RA2_COMPOSE_ULTRA_UDP_HOST=${RA2_COMPOSE_ULTRA_UDP_HOST:-1} . ./scripts/lib.sh; sh coturn/update_coturn_ip.sh 2>/dev/null || true; run_compose .env ${compose_action} ${SERVICES} ra2-coturn'"

echo "[redeploy-ultra] optional remote TURN probe (VPN on): sh scripts/probe-webrtc-turn-remote.sh"

for service in $SERVICES; do
  echo "[redeploy-ultra] verifying ${service}"
  container="$(player_container "$service")"
  ssh "$HOST" "sudo sh -c 'cd '\''$TARGET'\'' && . ./scripts/lib.sh && run_docker exec ${container} sh -lc '\\''
    set -eu
    test -x /opt/ra2/stream-helper || { echo \"stream-helper missing\"; exit 1; }
    pgrep -f ra2-stream-gateway.py >/dev/null || { echo \"gateway not running\"; exit 1; }
    pgrep -f \"Xvfb :1\" >/dev/null || { echo \"Xvfb missing\"; exit 1; }
    ! pgrep -f websockify >/dev/null || { echo \"websockify should be disabled in ultra mode\"; exit 1; }
    ! pgrep -f x11vnc >/dev/null || { echo \"x11vnc should be disabled in ultra mode\"; exit 1; }
    env | grep -E \"^ULTRA_VIDEO_|^ULTRA_GATEWAY_|^PLAYER_SERIAL=\"
  '\\'''"
  port="$(player_http_port "$service")"
  echo "[redeploy-ultra] ${service}: https://${NAS_LAN_IP}:${port}/"
  if [ "$service" = "ra2-player-1" ] || [ "$service" = "ra2-player-2" ]; then
    echo "[redeploy-ultra] verifying AoE II session prep in ${container}"
  ssh "$HOST" "sudo sh -c 'cd '\''$TARGET'\'' && CONTAINER='$container' sh scripts/verify-aoe2-session.sh '$container''"
  fi
done

echo "[redeploy-ultra] complete"
