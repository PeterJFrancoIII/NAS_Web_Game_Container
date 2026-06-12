#!/bin/sh
# Extract a DODI (Inno Setup) RA2/YR repack into a LAN-ready assets directory.
#
# The repack ships as Setup.exe + data1.doi (not plain game files). This script
# runs the installer under Wine, copies the result into ASSETS_OUT, then overlays
# cnc-ddraw + wsock32 from the current assets tree.
#
# Usage (on NAS):
#   cd /volume2/Data/App_Development/ra2-lan-party/project
#   DODI_INSTALLER_DIR=/volume2/Data/App_Development/ra2-lan-party/RA2Yuri_Game1 \
#     ASSETS_OUT=/volume2/Data/App_Development/ra2-lan-party/assets-game1 \
#     sh scripts/install-dodi-game-assets.sh
#
# Then point .env at the new tree and recreate the player:
#   ASSETS_DIR=/volume2/Data/App_Development/ra2-lan-party/assets-game1
#   NAS_HOST=MediaServer2Local RA2_ULTRA_BUILD=0 sh scripts/redeploy-ultra.sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

PROJECT_ROOT="${PROJECT_ROOT:-/volume2/Data/App_Development/ra2-lan-party}"
COMPOSE_DIR="${COMPOSE_DIR:-$PROJECT_ROOT/project}"
if [ -n "${DODI_INSTALLER_DIR:-}" ]; then
  DODI_ROOT="$DODI_INSTALLER_DIR"
elif [ -f "$COMPOSE_DIR/.env" ]; then
  DODI_ROOT="$(read_env_value DODI_INSTALLER_DIR "$PROJECT_ROOT/RA2Yuri_Game1" "$COMPOSE_DIR/.env")"
else
  DODI_ROOT="$PROJECT_ROOT/RA2Yuri_Game1"
fi
ASSETS_OUT="${ASSETS_OUT:-$PROJECT_ROOT/assets-game1}"
OVERLAY_ASSETS="${OVERLAY_ASSETS:-$PROJECT_ROOT/assets}"
IMAGE="${RA2_ULTRA_IMAGE:-ra2-lan-party:ultra}"
CONTAINER_UID="${CONTAINER_UID:-1000}"
CONTAINER_GID="${CONTAINER_GID:-1000}"

find_setup() {
  find "$DODI_ROOT" -maxdepth 3 -iname 'Setup.exe' 2>/dev/null | head -1
}

under_project_root() {
  case "$1" in
    "$PROJECT_ROOT"/*) return 0 ;;
    *) return 1 ;;
  esac
}

for dir in "$DODI_ROOT" "$ASSETS_OUT" "$OVERLAY_ASSETS"; do
  if ! under_project_root "$dir"; then
    echo "[dodi-install] paths must stay under $PROJECT_ROOT (refusing $dir)" >&2
    exit 1
  fi
done

SETUP_EXE="$(find_setup)"
if [ -z "$SETUP_EXE" ]; then
  echo "[dodi-install] Setup.exe not found under $DODI_ROOT" >&2
  exit 1
fi

INSTALLER_DIR="$(CDPATH= cd -- "$(dirname "$SETUP_EXE")" && pwd)"
mkdir -p "$ASSETS_OUT"
chown -R "$CONTAINER_UID:$CONTAINER_GID" "$ASSETS_OUT" "$DODI_ROOT" 2>/dev/null || true

echo "[dodi-install] installer: $SETUP_EXE"
echo "[dodi-install] output:    $ASSETS_OUT"
echo "[dodi-install] image:     $IMAGE"

run_docker run --rm --entrypoint /bin/sh \
  -v "$DODI_ROOT:/installer:ro" \
  -v "$ASSETS_OUT:/output" \
  -e DISPLAY=:99 \
  -e WINEPREFIX=/output/.wine-install \
  -e HOME=/output \
  --user "${CONTAINER_UID}:${CONTAINER_GID}" \
  "$IMAGE" -c "
set -eu
mkdir -p /output/.wine-install /output/game
# Wine maps z: -> / ; use Z:\\output\\game so files land on the mounted volume.
Xvfb :99 -screen 0 1024x768x24 -nolisten tcp >/dev/null 2>&1 &
XPID=\$!
sleep 2
export WINEDLLOVERRIDES='mscoree=d;mshtml=d'
wineboot --init
sleep 8
SETUP=\"\$(find /installer -maxdepth 3 -iname Setup.exe | head -1)\"
[ -n \"\$SETUP\" ] || { echo '[dodi-install] Setup.exe missing in /installer'; exit 1; }
cd \"\$(dirname \"\$SETUP\")\"
echo '[dodi-install] running Wine Setup.exe (may take several minutes)...'
wine \"\$(basename \"\$SETUP\")\" /SP- /VERYSILENT /SUPPRESSMSGBOXES /NOCANCEL /DIR=Z:\\\\output\\\\game
echo '[dodi-install] waiting for game files (up to 30 min)...'
i=0
while [ \"\$i\" -lt 180 ]; do
  if [ -f /output/game/RA2MD.exe ] || [ -f /output/game/gamemd.exe ]; then
    break
  fi
  sleep 10
  i=\$((i + 1))
done
wineserver -k 2>/dev/null || true
kill \"\$XPID\" 2>/dev/null || true
"

GAME_ROOT=""
for candidate in \
  "$ASSETS_OUT/game" \
  "$ASSETS_OUT/game/Red Alert 2" \
  "$ASSETS_OUT/game/Yuri's Revenge" \
  "$ASSETS_OUT/game/RA2" \
  "$ASSETS_OUT"; do
  if [ -f "$candidate/RA2MD.exe" ] || [ -f "$candidate/gamemd.exe" ]; then
    GAME_ROOT="$candidate"
    break
  fi
done

if [ -z "$GAME_ROOT" ]; then
  GAME_ROOT="$(find "$ASSETS_OUT" -iname RA2MD.exe 2>/dev/null | head -1)"
  GAME_ROOT="$(dirname "$GAME_ROOT")"
fi

if [ ! -f "$GAME_ROOT/RA2MD.exe" ] && [ ! -f "$GAME_ROOT/gamemd.exe" ]; then
  echo "[dodi-install] install finished but RA2MD.exe not found under $ASSETS_OUT" >&2
  find "$ASSETS_OUT" -maxdepth 4 -type d 2>/dev/null | head -30
  exit 1
fi

echo "[dodi-install] game root: $GAME_ROOT"

# Flatten: if game landed in a subfolder, symlink top-level names the container expects.
if [ "$GAME_ROOT" != "$ASSETS_OUT" ]; then
  echo "[dodi-install] game installed in subfolder; using $GAME_ROOT as asset root"
  ASSETS_OUT="$GAME_ROOT"
fi

for overlay in ddraw.dll ddraw.ini wsock32.dll ipxwrapper.ini "cnc-ddraw config.exe"; do
  if [ -f "$OVERLAY_ASSETS/$overlay" ]; then
    cp -f "$OVERLAY_ASSETS/$overlay" "$ASSETS_OUT/$overlay"
    echo "[dodi-install] overlaid $overlay"
  fi
done

if [ -f "$COMPOSE_DIR/config/ddraw.ini" ]; then
  cp -f "$COMPOSE_DIR/config/ddraw.ini" "$ASSETS_OUT/ddraw.ini"
fi

if [ -f "$COMPOSE_DIR/config/RA2MD.ini" ]; then
  cp -f "$COMPOSE_DIR/config/RA2MD.ini" "$ASSETS_OUT/RA2MD.ini"
fi

if ! grep -aq "cnc-ddraw" "$ASSETS_OUT/ddraw.dll" 2>/dev/null; then
  echo "[dodi-install] warning: ddraw.dll is not cnc-ddraw — run scripts/install-cnc-ddraw.sh" >&2
fi

rm -rf "$ASSETS_OUT/.wine-install" 2>/dev/null || true

echo "[dodi-install] complete: $ASSETS_OUT"
ls -lah "$ASSETS_OUT/RA2MD.exe" "$ASSETS_OUT/ddraw.dll" "$ASSETS_OUT/wsock32.dll" 2>/dev/null || \
  ls -lah "$ASSETS_OUT/"*.exe 2>/dev/null | head -5

echo ""
echo "Next: set ASSETS_DIR=$ASSETS_OUT in .env, then recreate the player:"
echo "  NAS_HOST=MediaServer2Local RA2_ULTRA_BUILD=0 sh scripts/redeploy-ultra.sh"
