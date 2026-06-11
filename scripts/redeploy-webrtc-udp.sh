#!/bin/sh
set -eu

# Enable UDP ICE test profile (TCP remains as fallback).
# Prefer macvlan for real LAN ICE: RA2_COMPOSE_WEBRTC_HOST=1

HOST="${NAS_HOST:-MediaServer2}"
TARGET="${NAS_TARGET:-/volume2/Data/App_Development/ra2-lan-party/project}"
BUILD_ON_NAS="${RA2_WEBRTC_BUILD:-0}"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"

echo "[redeploy-webrtc-udp] syncing project to ${HOST}:${TARGET}"
NAS_HOST="$HOST" NAS_TARGET="$TARGET" sh "$SCRIPT_DIR/sync-to-nas.sh"

if [ "$BUILD_ON_NAS" = "1" ]; then
  compose_action="up -d --build --force-recreate"
else
  compose_action="up -d --no-build --force-recreate"
fi

echo "[redeploy-webrtc-udp] recreating both players with UDP ICE enabled"
ssh "$HOST" "cd '$TARGET' && RA2_COMPOSE_WEBRTC=1 RA2_COMPOSE_WEBRTC_UDP=1 sh -c '. ./scripts/lib.sh; run_compose .env ${compose_action} ra2-player-1 ra2-player-2'"

echo "[redeploy-webrtc-udp] verifying ICE env inside containers"
ssh "$HOST" "cd '$TARGET' && sh -c '. ./scripts/lib.sh; run_docker exec ra2-player-1 sh -lc \"env | grep WEBRTC_ICE\"'"

echo "[redeploy-webrtc-udp] complete — open remote.html and confirm stats show transport=udp"
