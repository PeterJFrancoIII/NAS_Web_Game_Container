#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

PROJECT_ROOT="${PROJECT_ROOT:-/volume2/Data/App_Development/ra2-lan-party}"
CONTAINER_UID="${CONTAINER_UID:-1000}"
CONTAINER_GID="${CONTAINER_GID:-1000}"

for player in player1 player2; do
  prefix="$PROJECT_ROOT/prefixes/$player"
  mkdir -p "$prefix/rmcache"
  rm -rf "$prefix/drive_c" "$prefix/dosdevices"
  rm -f "$prefix/.ra2_initialized" "$prefix/.update-timestamp" "$prefix"/*.reg
done

if chown -R "$CONTAINER_UID:$CONTAINER_GID" "$PROJECT_ROOT/prefixes" 2>/dev/null; then
  :
elif sudo chown -R "$CONTAINER_UID:$CONTAINER_GID" "$PROJECT_ROOT/prefixes"; then
  :
else
  echo "Failed to set prefix ownership to $CONTAINER_UID:$CONTAINER_GID"
  exit 1
fi

echo "Wine prefixes reset. Rebuild and restart the containers next."
