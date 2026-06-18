#!/bin/sh
# Extract AoE II base + Conquerors ISO contents for Wine CD drive mounts.
set -eu

GAMES_ROOT="${GAMES_ROOT:-/volume2/Data/Games}"
PACKED_DIR="${PACKED_DIR:-${GAMES_ROOT}/1 Packed - Compressed/Age of Empires 2 II + The Conquerors + Patch 2.0a + Crack + Custom Maps (for Windows XP 7 8 8.1 10)}"
STAGE="${STAGE:-${GAMES_ROOT}/2 Unpacked - Ready to Play/Age of Empires 2/.disc-staging}"
OWNER="${GAMES_OWNER:-Viper117:users}"

log() {
  printf '[aoe2-discs] %s\n' "$*"
}

AOK_ISO="${PACKED_DIR}/AoE2.iso"
AOC_ISO="${PACKED_DIR}/AoE2_Conquerors.iso"
[ -f "$AOK_ISO" ] && [ -f "$AOC_ISO" ] || {
  log "missing AoE2.iso or AoE2_Conquerors.iso under ${PACKED_DIR}"
  exit 1
}

mkdir -p "$STAGE/aok_cd" "$STAGE/aoc_cd"
if [ ! -f "$STAGE/aok_cd/AUTORUN.INF" ]; then
  log "staging ${AOK_ISO}"
  if mountpoint="$(mktemp -d "${TMPDIR:-/tmp}/aoe2-aok.XXXXXX")"; then
    if mount -o loop,ro "$AOK_ISO" "$mountpoint" 2>/dev/null; then
      cp -a "$mountpoint/." "$STAGE/aok_cd/"
      umount "$mountpoint" 2>/dev/null || true
      rmdir "$mountpoint" 2>/dev/null || true
    else
      rmdir "$mountpoint" 2>/dev/null || true
      log "loop mount failed; trying 7z on ${AOK_ISO}"
      7z x -y -o"$STAGE/aok_cd" "$AOK_ISO" >/dev/null || log "warning: AoE2.iso staging incomplete"
    fi
  fi
fi
if [ ! -f "$STAGE/aoc_cd/AUTORUN.INF" ]; then
  log "staging ${AOC_ISO}"
  if mountpoint="$(mktemp -d "${TMPDIR:-/tmp}/aoe2-aoc.XXXXXX")"; then
    if mount -o loop,ro "$AOC_ISO" "$mountpoint" 2>/dev/null; then
      cp -a "$mountpoint/." "$STAGE/aoc_cd/"
      umount "$mountpoint" 2>/dev/null || true
      rmdir "$mountpoint" 2>/dev/null || true
    else
      rmdir "$mountpoint" 2>/dev/null || true
      log "loop mount failed; trying 7z on ${AOC_ISO}"
      7z x -y -o"$STAGE/aoc_cd" "$AOC_ISO" >/dev/null || log "warning: Conquerors ISO staging incomplete"
    fi
  fi
fi

sudo chown -R "$OWNER" "$STAGE" 2>/dev/null || true

empires2_crack="${PACKED_DIR}/empires2.exe"
aoc_crack="${STAGE}/aoc_cd/CRACK/AGE2_X1.EXE"
if [ -f "$empires2_crack" ] && [ -f "$STAGE/aok_cd/GAME/EMPIRES2.EXE" ]; then
  cp -f "$empires2_crack" "$STAGE/aok_cd/GAME/EMPIRES2.EXE"
  log "overlaid cracked EMPIRES2.EXE on aok_cd/GAME"
fi
if [ -f "$aoc_crack" ] && [ -f "$STAGE/aoc_cd/GAME/AGE2_X1/AGE2_X1.EXE" ]; then
  cp -f "$aoc_crack" "$STAGE/aoc_cd/GAME/AGE2_X1/AGE2_X1.EXE"
  log "overlaid cracked AGE2_X1.EXE on aoc_cd/GAME/AGE2_X1"
fi

log "ready: ${STAGE}/aok_cd and ${STAGE}/aoc_cd"
