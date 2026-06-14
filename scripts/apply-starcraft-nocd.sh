#!/bin/sh
# Apply Blizzard's official no-CD files (INSTALL.EXE renamed to *.mpq) to a StarCraft folder.
# See StarCraft patch 1.15.2+ release notes.
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

GAMES_ROOT="${GAMES_ROOT:-/volume2/Data/Games}"
PACKED_DIR="${PACKED_DIR:-${GAMES_ROOT}/1 Packed - Compressed/StarCraft & Brood War}"
DEST_DIR="${1:-${DEST_DIR:-${GAMES_ROOT}/2 Unpacked - Ready to Play/StarCraft}}"
STAGE="${STAGE:-/tmp/sc_unpack_stage}"
OWNER="${GAMES_OWNER:-Viper117:users}"

log() {
  printf '[sc-nocd] %s\n' "$*"
}

[ -d "$DEST_DIR" ] || {
  log "destination missing: ${DEST_DIR}"
  exit 1
}

SC_ISO="$(find "$PACKED_DIR" -maxdepth 1 -type f -iname 'STARCRAFT.iso' | head -1)"
BW_ISO="$(find "$PACKED_DIR" -maxdepth 1 -type f -iname 'BROODWAR.iso' | head -1)"

mkdir -p "$STAGE/sc_cd" "$STAGE/bw_cd"

if [ -n "$SC_ISO" ]; then
  7z x -y -o"$STAGE/sc_cd" "$SC_ISO" INSTALL.EXE >/dev/null
  cp -f "$STAGE/sc_cd/INSTALL.EXE" "$DEST_DIR/StarCraft.mpq"
  log "StarCraft.mpq from ${SC_ISO}"
elif [ -f "$STAGE/sc_cd/INSTALL.EXE" ]; then
  cp -f "$STAGE/sc_cd/INSTALL.EXE" "$DEST_DIR/StarCraft.mpq"
else
  log "warning: STARCRAFT.iso not found; StarCraft.mpq unchanged"
fi

if [ -n "$BW_ISO" ]; then
  7z x -y -o"$STAGE/bw_cd" "$BW_ISO" INSTALL.EXE >/dev/null
  cp -f "$STAGE/bw_cd/INSTALL.EXE" "$DEST_DIR/BroodWar.mpq"
  log "BroodWar.mpq from ${BW_ISO}"
elif [ -f "$STAGE/bw_cd/INSTALL.EXE" ]; then
  cp -f "$STAGE/bw_cd/INSTALL.EXE" "$DEST_DIR/BroodWar.mpq"
else
  log "warning: BROODWAR.iso not found; BroodWar.mpq unchanged"
fi

if [ -f "$DEST_DIR/StarCraft.mpq" ] && [ -f "$DEST_DIR/BroodWar.mpq" ]; then
  log "no-CD files ready under ${DEST_DIR}"
else
  log "ERROR: missing StarCraft.mpq or BroodWar.mpq in ${DEST_DIR}"
  exit 1
fi

if [ ! -f "$DEST_DIR/Brood War.exe" ] && [ -f "$DEST_DIR/StarCraft.exe" ]; then
  cp -f "$DEST_DIR/StarCraft.exe" "$DEST_DIR/Brood War.exe"
  log "created Brood War.exe from StarCraft.exe"
fi

sudo chown -R "$OWNER" "$DEST_DIR" 2>/dev/null || true
chmod -R u+rwX,g+rwX "$DEST_DIR" 2>/dev/null || true
