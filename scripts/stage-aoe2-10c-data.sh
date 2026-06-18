#!/bin/sh
# Stage AoE II 1.0c patch data by extracting Microsoft patch CABs on the NAS host.
# Run once on MediaServer2: sh scripts/stage-aoe2-10c-data.sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
COMPOSE_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
PATCH_SRC="${AOE2_PATCH_HOST:-/volume2/Data/Games/1 Packed - Compressed/Age of Empires 2 II + The Conquerors + Patch 2.0a + Crack + Custom Maps (for Windows XP 7 8 8.1 10)}"
OUT_DIR="${AOE2_10C_DATA_HOST:-$COMPOSE_DIR/aoe2-10c-data}"
PATCH_EXE="${PATCH_SRC}/AoE2_Conquerors_patch.exe"

if ! command -v 7z >/dev/null 2>&1; then
  echo "[aoe2-10c] 7z is required on the NAS host" >&2
  exit 1
fi
if [ ! -f "$PATCH_EXE" ]; then
  echo "[aoe2-10c] missing patch exe: $PATCH_EXE" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT HUP TERM

7z x -o"$tmp" "$PATCH_EXE" "data/empires2_x1_p1.dat" "data/gamedata_x1_p1.drs" >/dev/null
mkdir -p "$OUT_DIR"
cp -f "$tmp/data/empires2_x1_p1.dat" "$OUT_DIR/empires2_x1_p1.dat"
cp -f "$tmp/data/gamedata_x1_p1.drs" "$OUT_DIR/gamedata_x1_p1.drs"

ISO="${PATCH_SRC}/AoE2_Conquerors.iso"
if [ -f "$ISO" ]; then
  7z x -o"$tmp/iso" "$ISO" "GAME/AGE2_X1/AGE2_X1.EXE" >/dev/null 2>&1 || true
  if [ -f "$tmp/iso/GAME/AGE2_X1/AGE2_X1.EXE" ]; then
    cp -f "$tmp/iso/GAME/AGE2_X1/AGE2_X1.EXE" "$OUT_DIR/age2_x1_10c.exe"
    echo "[aoe2-10c] staged original 1.0c age2_x1.exe ($(wc -c <"$OUT_DIR/age2_x1_10c.exe" | tr -d ' ') bytes)"
  fi
fi

echo "[aoe2-10c] staged $(wc -c <"$OUT_DIR/empires2_x1_p1.dat" | tr -d ' ') byte empires2_x1_p1.dat -> $OUT_DIR"
