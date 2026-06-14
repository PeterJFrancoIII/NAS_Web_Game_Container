#!/bin/sh
# Copy a completed StarCraft install from ra2-player-1 into the LAN-ready folder.
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

GAMES_ROOT="${GAMES_ROOT:-/volume2/Data/Games}"
PACKED_DIR="${PACKED_DIR:-${GAMES_ROOT}/1 Packed - Compressed/StarCraft & Brood War}"
DEST_DIR="${DEST_DIR:-${GAMES_ROOT}/2 Unpacked - Ready to Play/StarCraft}"
STAGE="${STAGE:-/tmp/sc_unpack_stage}"
PLAYER="${RA2_ULTRA_SERVICE:-ra2-player-1}"
OWNER="${GAMES_OWNER:-Viper117:users}"

log() {
  printf '[sc-finalize] %s\n' "$*"
}

find_game_root() {
  run_docker exec "$PLAYER" /bin/sh -c '
for candidate in \
  "/home/commander/sc_assets" \
  "/home/commander/.wine/drive_c/Starcraft" \
  "/home/commander/.wine/drive_c/Program Files/StarCraft" \
  "/home/commander/.wine/drive_c/Program Files (x86)/StarCraft" \
  "/home/commander/.wine/drive_c/StarCraft"; do
  if [ -f "$candidate/Brood War.exe" ] || [ -f "$candidate/Starcraft.exe" ]; then
    printf "%s\n" "$candidate"
    exit 0
  fi
done
exit 1
'
}

if [ "$(container_status "$PLAYER")" != "running" ]; then
  log "${PLAYER} is not running"
  exit 1
fi

GAME_ROOT="$(find_game_root)" || {
  log "Brood War.exe not found in ${PLAYER}. Finish SETUP in the browser stream first."
  exit 1
}

log "found install at ${GAME_ROOT}"
sudo mkdir -p "$DEST_DIR"
sudo rm -rf "$DEST_DIR"/*
sudo chown -R "$OWNER" "$DEST_DIR" 2>/dev/null || true
run_docker exec "$PLAYER" /bin/sh -c "cp -a '${GAME_ROOT}/.' /home/commander/sc_assets/" 2>/dev/null || \
  sudo /usr/local/bin/docker cp "${PLAYER}:${GAME_ROOT}/." "$DEST_DIR/"
sudo chown -R "$OWNER" "$DEST_DIR" 2>/dev/null || true

if [ -f "$STAGE/sc_cd/INSTALL.EXE" ]; then
  cp -f "$STAGE/sc_cd/INSTALL.EXE" "$DEST_DIR/StarCraft.mpq"
fi
if [ -f "$STAGE/bw_cd/INSTALL.EXE" ]; then
  cp -f "$STAGE/bw_cd/INSTALL.EXE" "$DEST_DIR/BroodWar.mpq"
fi
if [ -f "$PACKED_DIR/STARCRAFT.iso" ] && [ ! -f "$DEST_DIR/StarCraft.mpq" ]; then
  7z x -y -o"$STAGE/sc_cd" "$PACKED_DIR/STARCRAFT.iso" INSTALL.EXE >/dev/null 2>&1 || true
  cp -f "$STAGE/sc_cd/INSTALL.EXE" "$DEST_DIR/StarCraft.mpq" 2>/dev/null || true
fi
if [ -f "$PACKED_DIR/BROODWAR.iso" ] && [ ! -f "$DEST_DIR/BroodWar.mpq" ]; then
  7z x -y -o"$STAGE/bw_cd" "$PACKED_DIR/BROODWAR.iso" INSTALL.EXE >/dev/null 2>&1 || true
  cp -f "$STAGE/bw_cd/INSTALL.EXE" "$DEST_DIR/BroodWar.mpq" 2>/dev/null || true
fi

if [ ! -f "$DEST_DIR/Brood War.exe" ] && [ -f "$DEST_DIR/StarCraft.exe" ]; then
  cp -f "$DEST_DIR/StarCraft.exe" "$DEST_DIR/Brood War.exe"
fi

/bin/sh "$SCRIPT_DIR/apply-starcraft-nocd.sh" "$DEST_DIR"

[ -f "$DEST_DIR/Brood War.exe" ] || [ -f "$DEST_DIR/StarCraft.exe" ] || {
  log "ERROR: ${DEST_DIR}/Brood War.exe missing"
  exit 1
}
[ -f "$DEST_DIR/StarCraft.mpq" ] && [ -f "$DEST_DIR/BroodWar.mpq" ] || {
  log "ERROR: no-CD files missing; run scripts/apply-starcraft-nocd.sh"
  exit 1
}

sudo chown -R "$OWNER" "$DEST_DIR" 2>/dev/null || true
chmod -R u+rwX,g+rwX "$DEST_DIR" 2>/dev/null || true
log "done: ${DEST_DIR}"
log "StarCraft should appear in the game picker after a hard refresh."
