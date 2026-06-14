#!/bin/sh
# Stage StarCraft ISOs and launch Blizzard SETUP in ra2-player-1.
# Complete the installer in the browser stream (https://192.168.0.193:6081/).
#
# After both StarCraft and Brood War setup wizards finish, run:
#   sh scripts/finalize-starcraft-install.sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

GAMES_ROOT="${GAMES_ROOT:-/volume2/Data/Games}"
PACKED_DIR="${PACKED_DIR:-${GAMES_ROOT}/1 Packed - Compressed/StarCraft & Brood War}"
STAGE="${STAGE:-/tmp/sc_unpack_stage}"
PLAYER="${RA2_ULTRA_SERVICE:-ra2-player-1}"
NAS_LAN_IP="${NAS_LAN_IP:-192.168.0.193}"

log() {
  printf '[sc-setup] %s\n' "$*"
}

if [ "$(container_status "$PLAYER")" != "running" ]; then
  log "${PLAYER} is not running. Redeploy first:"
  log "  NAS_HOST=MediaServer2Local RA2_ULTRA_BUILD=0 sh scripts/redeploy-ultra.sh"
  exit 1
fi

SC_ISO="$(find "$PACKED_DIR" -maxdepth 1 -type f -iname 'STARCRAFT.iso' | head -1)"
BW_ISO="$(find "$PACKED_DIR" -maxdepth 1 -type f -iname 'BROODWAR.iso' | head -1)"
[ -n "$SC_ISO" ] && [ -n "$BW_ISO" ] || {
  log "missing STARCRAFT.iso or BROODWAR.iso under ${PACKED_DIR}"
  exit 1
}

mkdir -p "$STAGE/sc_cd" "$STAGE/bw_cd"
7z x -y -o"$STAGE/sc_cd" "$SC_ISO" >/dev/null
7z x -y -o"$STAGE/bw_cd" "$BW_ISO" >/dev/null

run_docker cp "$STAGE/sc_cd/." "${PLAYER}:/tmp/sc_install_sc"
run_docker cp "$STAGE/bw_cd/." "${PLAYER}:/tmp/sc_install_bw"

/bin/sh "$SCRIPT_DIR/prepare-starcraft-wine-install.sh" 2>/dev/null || true

log "Launching StarCraft base SETUP in ${PLAYER}."
log "Open https://${NAS_LAN_IP}:6081/ and complete the installer (CD key is in CD Key.txt on the NAS)."
run_docker exec -d -e DISPLAY=:1 "$PLAYER" /bin/sh -c \
  'export WINEDLLOVERRIDES=mscoree=d;mshtml=d;comctl32=b; cd /tmp/sc_install_sc; wine ./SETUP.EXE'

log "When StarCraft base install finishes, launch Brood War:"
log "  ssh MediaServer2Local 'sudo docker exec -d -e DISPLAY=:1 ra2-player-1 sh -c \"export WINEDLLOVERRIDES=mscoree=d;mshtml=d;comctl32=b; cd /tmp/sc_install_bw; wine ./SETUP.EXE\"'"
log "Then finalize:"
log "  ssh MediaServer2Local 'cd /volume2/Data/App_Development/ra2-lan-party/project && sh scripts/finalize-starcraft-install.sh'"
