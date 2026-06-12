#!/bin/sh
# Sync Mac -> NAS disk, then push the project mirror into /dev/shm and reload services.
# All container bind mounts read from RAM — no HDD on the hot debug path.
#
#   NAS_HOST=MediaServer2Local sh scripts/sync-to-ram.sh
#   NAS_HOST=MediaServer2Local sh scripts/sync-to-ram.sh gw    # mirror + gateway only
#   NAS_HOST=MediaServer2Local sh scripts/sync-to-ram.sh up    # first boot / recreate
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
HOST="${NAS_HOST:-MediaServer2Local}"
TARGET="${NAS_TARGET:-/volume2/Data/App_Development/ra2-lan-party/project}"
ACTION="${1:-refresh}"
SERVICE="${RA2_RAM_SERVICE:-ra2-player-dev}"

NAS_HOST="$HOST" NAS_TARGET="$TARGET" sh "$SCRIPT_DIR/sync-to-nas.sh"

case "$ACTION" in
  refresh|gw|audio|up|recreate|status)
    ;;
  *)
    echo "usage: $0 [refresh|gw|audio|up|recreate|status]" >&2
    exit 1
    ;;
esac

if [ "$ACTION" = "refresh" ]; then
  running="$(ssh "$HOST" "sudo -n /usr/local/bin/docker inspect -f '{{.State.Running}}' $SERVICE 2>/dev/null" || true)"
  if [ "$running" != "true" ]; then
    echo "[sync-to-ram] $SERVICE not running — starting RAM stack"
    ACTION=up
  fi
fi

ssh "$HOST" "cd '$TARGET' && sudo -n sh -c 'RA2_RAM_LOCAL=1 sh scripts/dev-ram-ultra.sh $ACTION'"

HTTP_PORT="${DEV_RAM_HTTP_PORT:-6091}"
NAS_LAN_IP="${NAS_LAN_IP:-192.168.0.193}"
echo ""
echo "[sync-to-ram] debug URL: https://${NAS_LAN_IP}:${HTTP_PORT}/"
echo "[sync-to-ram] iterate: edit locally, then re-run this script"
