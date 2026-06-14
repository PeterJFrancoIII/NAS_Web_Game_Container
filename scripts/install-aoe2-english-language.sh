#!/bin/sh
# Install English AoE II (1999) language files for the container overlay.
#
# Classic Age of Kings reads LANGUAGE.DLL from the game folder. The NAS unpack
# is Italian; this script copies English LANGUAGE.DLL (+ optional History/) into
# config/aoe2-language/ so run-game-session.sh can overlay them at launch.
#
# Obtain English files from your own English install or the AoEZone community pack
# (search "AoC Language Files" → English / aoc_english.zip).
#
# Usage:
#   sh scripts/install-aoe2-english-language.sh /path/to/aoc_english.zip
#   sh scripts/install-aoe2-english-language.sh /path/to/english/Age\ of\ Empires\ 2
#   AOE2_ENGLISH_SOURCE=/path/to/source sh scripts/install-aoe2-english-language.sh
#
# Then sync and recreate the player:
#   NAS_HOST=MediaServer2 sh scripts/sync-to-nas.sh
#   RA2_ULTRA_BUILD=0 RA2_ULTRA_SERVICE=ra2-player-1 NAS_HOST=MediaServer2 sh scripts/redeploy-ultra.sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
COMPOSE_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${AOE2_LANGUAGE_DIR:-$COMPOSE_DIR/config/aoe2-language}"
SOURCE="${1:-${AOE2_ENGLISH_SOURCE:-}}"

find_language_dll() {
  root="$1"
  for name in LANGUAGE.DLL language.dll Language.dll; do
    if [ -f "$root/$name" ]; then
      printf '%s\n' "$root/$name"
      return 0
    fi
  done
  find "$root" -maxdepth 3 \( -iname 'LANGUAGE.DLL' -o -iname 'language.dll' \) 2>/dev/null | head -1
}

install_from_dir() {
  src_dir="$1"
  dll="$(find_language_dll "$src_dir")"
  if [ -z "$dll" ]; then
    echo "[aoe2-lang] no LANGUAGE.DLL under $src_dir" >&2
    return 1
  fi
  mkdir -p "$OUT_DIR"
  cp -f "$dll" "$OUT_DIR/LANGUAGE.DLL"
  if [ -d "$src_dir/History" ]; then
    rm -rf "$OUT_DIR/History"
    cp -a "$src_dir/History" "$OUT_DIR/History"
  fi
}

install_from_zip() {
  zip_path="$1"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/aoe2-lang.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT INT HUP
  unzip -q "$zip_path" -d "$tmp"
  install_from_dir "$tmp"
}

if [ -z "$SOURCE" ]; then
  echo "Usage: $0 /path/to/aoc_english.zip|/path/to/english/game/dir" >&2
  echo "  or set AOE2_ENGLISH_SOURCE" >&2
  exit 1
fi

if [ ! -e "$SOURCE" ]; then
  echo "[aoe2-lang] source not found: $SOURCE" >&2
  exit 1
fi

case "$SOURCE" in
  *.zip|*.ZIP)
    install_from_zip "$SOURCE"
    ;;
  *)
    if [ -d "$SOURCE" ]; then
      install_from_dir "$SOURCE"
    else
      echo "[aoe2-lang] unsupported source (need .zip or directory): $SOURCE" >&2
      exit 1
    fi
    ;;
esac

if [ ! -f "$OUT_DIR/LANGUAGE.DLL" ]; then
  echo "[aoe2-lang] install failed: $OUT_DIR/LANGUAGE.DLL missing" >&2
  exit 1
fi

echo "[aoe2-lang] installed English LANGUAGE.DLL -> $OUT_DIR/LANGUAGE.DLL"
if [ -d "$OUT_DIR/History" ]; then
  echo "[aoe2-lang] installed History/ ($(find "$OUT_DIR/History" -type f | wc -l | tr -d ' ') files)"
else
  echo "[aoe2-lang] note: History/ not present (in-game history text may stay Italian)"
fi
