#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

PROJECT_ROOT="${PROJECT_ROOT:-/volume2/Data/App_Development/ra2-lan-party}"
ASSETS_DIR="${ASSETS_DIR:-$PROJECT_ROOT/assets}"
COMPOSE_DIR="${COMPOSE_DIR:-$PROJECT_ROOT/project}"
CNC_DDRAW_URL="${CNC_DDRAW_URL:-https://github.com/FunkyFr3sh/cnc-ddraw/releases/latest/download/cnc-ddraw.zip}"

mkdir -p "$ASSETS_DIR"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT INT HUP TERM

archive="$tmp_dir/cnc-ddraw.zip"
echo "Downloading cnc-ddraw from $CNC_DDRAW_URL"
curl -fsSL -o "$archive" "$CNC_DDRAW_URL"

extract_zip() {
  if command -v unzip >/dev/null 2>&1; then
    unzip -oq "$1" ddraw.dll "cnc-ddraw config.exe" -d "$2"
    return
  fi

  python3 - "$1" "$2" <<'PY'
import sys
import zipfile

archive, out_dir = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(archive) as zf:
    for name in ("ddraw.dll", "cnc-ddraw config.exe"):
        zf.extract(name, out_dir)
PY
}

if ! extract_zip "$archive" "$tmp_dir"; then
  echo "Failed to extract cnc-ddraw.zip"
  exit 1
fi

if ! grep -aq "cnc-ddraw" "$tmp_dir/ddraw.dll"; then
  echo "Extracted ddraw.dll does not look like cnc-ddraw."
  exit 1
fi

cp "$tmp_dir/ddraw.dll" "$ASSETS_DIR/ddraw.dll"
cp "$tmp_dir/cnc-ddraw config.exe" "$ASSETS_DIR/cnc-ddraw config.exe"

if [ -f "$COMPOSE_DIR/config/ddraw.ini" ]; then
  cp "$COMPOSE_DIR/config/ddraw.ini" "$ASSETS_DIR/ddraw.ini"
fi

echo "Installed cnc-ddraw into $ASSETS_DIR"
ls -lah "$ASSETS_DIR/ddraw.dll" "$ASSETS_DIR/ddraw.ini" "$ASSETS_DIR/cnc-ddraw config.exe"
