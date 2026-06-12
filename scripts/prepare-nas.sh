#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-/volume2/Data/App_Development/ra2-lan-party}"
CONTAINER_UID="${CONTAINER_UID:-1000}"
CONTAINER_GID="${CONTAINER_GID:-1000}"

# All project data lives under PROJECT_ROOT (DSM: /volume2/Data/App_Development/ra2-lan-party).
mkdir -p \
  "$PROJECT_ROOT/RA2Yuri_Game1" \
  "$PROJECT_ROOT/assets" \
  "$PROJECT_ROOT/assets-game1" \
  "$PROJECT_ROOT/prefixes/player1-win32" \
  "$PROJECT_ROOT/prefixes/player1-win32/rmcache" \
  "$PROJECT_ROOT/prefixes/player2-win32" \
  "$PROJECT_ROOT/prefixes/player2-win32/rmcache" \
  "$PROJECT_ROOT/logs/player1" \
  "$PROJECT_ROOT/logs/player2" \
  "$PROJECT_ROOT/project" \
  "$PROJECT_ROOT/tls" \
  "$PROJECT_ROOT/logs"

chmod 755 "$PROJECT_ROOT"
chmod 755 "$PROJECT_ROOT/assets" "$PROJECT_ROOT/RA2Yuri_Game1" "$PROJECT_ROOT/assets-game1" 2>/dev/null || true

sh "$SCRIPT_DIR/fix-prefix-perms.sh"

cat <<EOF
Prepared RA2 LAN party directories (everything under Data/App_Development/ra2-lan-party):

  $PROJECT_ROOT/RA2Yuri_Game1     DODI installer drop (Setup.exe + data1.doi)
  $PROJECT_ROOT/assets-game1     extracted game + LAN overlays (install script output)
  $PROJECT_ROOT/assets           legacy/active game mount (set ASSETS_DIR in .env)
  $PROJECT_ROOT/prefixes/player1-win32
  $PROJECT_ROOT/prefixes/player2-win32
  $PROJECT_ROOT/project          compose repo (synced from Mac)
  $PROJECT_ROOT/logs
  $PROJECT_ROOT/tls

Next:
  1. Place DODI repack under $PROJECT_ROOT/RA2Yuri_Game1, then:
     cd $PROJECT_ROOT/project && sh scripts/install-dodi-game-assets.sh
  2. Or copy your legally owned RA2/YR files into $PROJECT_ROOT/assets and add
     cnc-ddraw + wsock32.dll (scripts/install-cnc-ddraw.sh).
  3. Set ASSETS_DIR in $PROJECT_ROOT/project/.env to assets or assets-game1.
  4. Edit .env passwords and serials; run: sh scripts/bootstrap-nas.sh build
EOF
