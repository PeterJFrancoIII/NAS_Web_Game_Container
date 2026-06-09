#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-/volume2/Data/App_Development/ra2-lan-party}"
CONTAINER_UID="${CONTAINER_UID:-1000}"
CONTAINER_GID="${CONTAINER_GID:-1000}"

mkdir -p \
  "$PROJECT_ROOT/assets" \
  "$PROJECT_ROOT/prefixes/player1" \
  "$PROJECT_ROOT/prefixes/player1/rmcache" \
  "$PROJECT_ROOT/prefixes/player2" \
  "$PROJECT_ROOT/prefixes/player2/rmcache" \
  "$PROJECT_ROOT/project" \
  "$PROJECT_ROOT/logs"

chmod 755 "$PROJECT_ROOT"
chmod 755 "$PROJECT_ROOT/assets"

sh "$SCRIPT_DIR/fix-prefix-perms.sh"

cat <<EOF
Prepared RA2 LAN party directories:

  $PROJECT_ROOT/assets
  $PROJECT_ROOT/prefixes/player1
  $PROJECT_ROOT/prefixes/player2
  $PROJECT_ROOT/project
  $PROJECT_ROOT/logs

Next:
  1. Copy your legally owned Red Alert 2 / Yuri's Revenge files into:
     $PROJECT_ROOT/assets
  2. Add cnc-ddraw files and an IPX-to-UDP wsock32.dll wrapper to that same assets folder.
  3. Edit $PROJECT_ROOT/project/.env passwords and serials.
  4. Run: sh $PROJECT_ROOT/project/scripts/bootstrap-nas.sh build
EOF
