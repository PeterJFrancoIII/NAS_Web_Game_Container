#!/bin/sh
# Extract full StarCraft + Brood War ISO contents for Wine CD drive mounts.
set -eu

GAMES_ROOT="${GAMES_ROOT:-/volume2/Data/Games}"
PACKED_DIR="${PACKED_DIR:-${GAMES_ROOT}/1 Packed - Compressed/StarCraft & Brood War}"
STAGE="${STAGE:-${GAMES_ROOT}/2 Unpacked - Ready to Play/StarCraft/.disc-staging}"
OWNER="${GAMES_OWNER:-Viper117:users}"

log() {
  printf '[sc-discs] %s\n' "$*"
}

SC_ISO="$(find "$PACKED_DIR" -maxdepth 1 -type f -iname 'STARCRAFT.iso' | head -1)"
BW_ISO="$(find "$PACKED_DIR" -maxdepth 1 -type f -iname 'BROODWAR.iso' | head -1)"
[ -n "$SC_ISO" ] && [ -n "$BW_ISO" ] || {
  log "missing STARCRAFT.iso or BROODWAR.iso under ${PACKED_DIR}"
  exit 1
}

mkdir -p "$STAGE/sc_cd" "$STAGE/bw_cd"
if [ ! -f "$STAGE/sc_cd/SETUP.EXE" ]; then
  log "extracting ${SC_ISO}"
  7z x -y -o"$STAGE/sc_cd" "$SC_ISO" >/dev/null
fi
if [ ! -f "$STAGE/bw_cd/SETUP.EXE" ]; then
  log "extracting ${BW_ISO}"
  7z x -y -o"$STAGE/bw_cd" "$BW_ISO" >/dev/null
fi

sudo chown -R "$OWNER" "$STAGE" 2>/dev/null || true
log "ready: ${STAGE}/sc_cd and ${STAGE}/bw_cd"
