#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

PROJECT_ROOT="${PROJECT_ROOT:-/volume2/Data/App_Development/ra2-lan-party}"
ASSETS_DIR="${ASSETS_DIR:-$PROJECT_ROOT/assets}"
COMPOSE_DIR="${COMPOSE_DIR:-$PROJECT_ROOT/project}"
SOURCE_DIR="${1:-}"

cd "$COMPOSE_DIR"
GAME_EXE="$(read_env_value GAME_EXE RA2MD.exe .env)"

mkdir -p "$ASSETS_DIR"

if [ -n "$SOURCE_DIR" ]; then
  if [ ! -d "$SOURCE_DIR" ]; then
    echo "Source directory not found: $SOURCE_DIR"
    exit 1
  fi

  echo "Copying assets from $SOURCE_DIR"
  cp -a "$SOURCE_DIR/." "$ASSETS_DIR/"
fi

for template in ddraw.ini RA2.ini RA2MD.ini ipxwrapper.ini; do
  if [ -f "$COMPOSE_DIR/config/$template" ]; then
    cp "$COMPOSE_DIR/config/$template" "$ASSETS_DIR/$template"
  fi
done

# Wine runs on a case-sensitive filesystem, while RA2 historically expects
# Windows-style case-insensitive lookups. Keep both common Yuri config names
# synchronized when the source assets include the uppercase variant.
if [ -f "$ASSETS_DIR/RA2MD.ini" ] && [ -f "$ASSETS_DIR/RA2MD.INI" ]; then
  cp "$ASSETS_DIR/RA2MD.ini" "$ASSETS_DIR/RA2MD.INI"
fi

missing=0
for required in "$GAME_EXE" ddraw.dll wsock32.dll; do
  if [ ! -f "$ASSETS_DIR/$required" ]; then
    echo "Still missing: $ASSETS_DIR/$required"
    missing=1
  fi
done

if [ ! -f "$ASSETS_DIR/ddraw.ini" ]; then
  echo "Still missing: $ASSETS_DIR/ddraw.ini"
  missing=1
fi

if [ "$missing" -ne 0 ]; then
  echo
  echo "Asset ingest incomplete. Required:"
  echo "  $GAME_EXE (or set GAME_EXE in .env)"
  echo "  ddraw.dll"
  echo "  ddraw.ini"
  echo "  wsock32.dll"
  exit 1
fi

if ! grep -aq "cnc-ddraw" "$ASSETS_DIR/ddraw.dll" 2>/dev/null; then
  echo "ddraw.dll is not cnc-ddraw. Installing the correct wrapper..."
  sh "$SCRIPT_DIR/install-cnc-ddraw.sh"
fi

echo "Asset ingest complete."
ls -lah "$ASSETS_DIR"
