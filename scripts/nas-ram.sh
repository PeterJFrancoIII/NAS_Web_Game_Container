#!/bin/sh
# Run ON the Synology NAS (SSH in, then use this script).
#
# Staging copy on disk (optional seed source):
#   /volume2/Data/App_Development/ra2-lan-party/project
#
# Hot edit path — container bind mounts read from here (tmpfs, no HDD):
#   /dev/shm/ra2-dev/project
#
# Typical NAS workflow:
#   sudo sh scripts/nas-ram.sh up        # once: mirror disk -> RAM, start ra2-player-dev
#   sudo nano /dev/shm/ra2-dev/project/container/remote-ultra/ultra-play.js
#   sudo sh scripts/nas-ram.sh gw        # ~2s: reload gateway from RAM
#   sudo sh scripts/nas-ram.sh game      # restart game (ddraw.ini, etc.)
#
# If you edited the disk copy instead of RAM:
#   sudo sh scripts/nas-ram.sh refresh   # disk -> RAM mirror + restart gw + game
#
# Debug URL: https://192.168.0.193:6091/
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
DISK_PROJECT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
RAM_PROJECT="${RAM_PROJECT_DIR:-/dev/shm/ra2-dev/project}"
ACTION="${1:-status}"

run_dev_ram() {
  export RA2_RAM_LOCAL=1
  if [ "$(id -u)" -eq 0 ]; then
    sh "$DISK_PROJECT/scripts/dev-ram-ultra.sh" "$@"
  elif sudo -n true 2>/dev/null; then
    sudo -n sh "$DISK_PROJECT/scripts/dev-ram-ultra.sh" "$@"
  else
    echo "nas-ram: run with sudo on the NAS, e.g. sudo sh scripts/nas-ram.sh $*" >&2
    exit 1
  fi
}

case "$ACTION" in
  paths)
    echo "disk staging:  $DISK_PROJECT"
    echo "RAM hot path:    $RAM_PROJECT"
    echo "RAM prefix:      ${RAM_PREFIX_DIR:-/dev/shm/ra2-dev/prefix-player1}"
    echo "RAM assets:      ${RAM_ASSETS_DIR:-/dev/shm/ra2-dev/assets}"
    echo "container:       ${RA2_RAM_SERVICE:-ra2-player-dev}"
    echo "URL:             https://${NAS_LAN_IP:-192.168.0.193}:${DEV_RAM_HTTP_PORT:-6091}/"
    ;;
  game)
    run_dev_ram game
    ;;
  *)
    run_dev_ram "$ACTION"
    ;;
esac
