#!/bin/sh
# Apply Blizzard SC-1161 patch (no-CD after StarCraft.mpq + BroodWar.mpq are present).
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

DEST_DIR="${1:-${GAMES_ROOT:-/volume2/Data/Games}/2 Unpacked - Ready to Play/StarCraft}"
PLAYER="${RA2_ULTRA_SERVICE:-ra2-player-1}"
PATCH="${PATCH:-/tmp/sc-1161.exe}"
PATCH_URL="${PATCH_URL:-http://ftp.blizzard.com/pub/starcraft/patches/PC/SC-1161.exe}"

log() {
  printf '[sc-patch] %s\n' "$*"
}

[ -d "$DEST_DIR" ] || { log "missing ${DEST_DIR}"; exit 1; }
[ -f "$DEST_DIR/StarCraft.mpq" ] && [ -f "$DEST_DIR/BroodWar.mpq" ] || {
  log "run scripts/apply-starcraft-nocd.sh first"
  exit 1
}

if [ ! -f "$PATCH" ]; then
  log "downloading SC-1161 patch"
  wget -q -O "$PATCH" "$PATCH_URL" || wget -q -O "$PATCH" "https://archive.org/download/starcraft-brood-war-patch-v1.16.1/SC-1161.exe"
fi

[ "$(container_status "$PLAYER")" = "running" ] || { log "${PLAYER} not running"; exit 1; }

run_docker cp "$PATCH" "${PLAYER}:/tmp/sc-1161.exe"
run_docker cp "$DEST_DIR/." "${PLAYER}:/tmp/sc_patch_target/"
run_docker exec -u commander -e DISPLAY=:1 -e WINEDLLOVERRIDES="mscoree=d;mshtml=d;comctl32=b" "$PLAYER" /bin/sh -c '
set -eu
cd /tmp/sc_patch_target
wine /tmp/sc-1161.exe >/tmp/sc-1161.log 2>&1 || true
sleep 20
wineserver -k >/dev/null 2>&1 || true
ls -la StarCraft.exe "Brood War.exe" 2>/dev/null || ls -la *.exe
'
run_docker cp "${PLAYER}:/tmp/sc_patch_target/." "$DEST_DIR/"

if [ ! -f "$DEST_DIR/Brood War.exe" ] && [ -f "$DEST_DIR/StarCraft.exe" ]; then
  cp -f "$DEST_DIR/StarCraft.exe" "$DEST_DIR/Brood War.exe"
fi

log "patched ${DEST_DIR}"
