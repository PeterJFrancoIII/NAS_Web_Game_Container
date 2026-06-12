#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

PROJECT_ROOT="${PROJECT_ROOT:-/volume2/Data/App_Development/ra2-lan-party}"
CONTAINER_UID="${CONTAINER_UID:-1000}"
CONTAINER_GID="${CONTAINER_GID:-1000}"

PREFIX1="${PREFIX1_DIR:-$PROJECT_ROOT/prefixes/player1-win32}"
PREFIX2="${PREFIX2_DIR:-$PROJECT_ROOT/prefixes/player2-win32}"
LOGS="$PROJECT_ROOT/logs"

mkdir -p "$PREFIX1/rmcache" "$PREFIX2/rmcache" "$LOGS/player1" "$LOGS/player2"

chown_paths() {
  chown -R "$CONTAINER_UID:$CONTAINER_GID" "$PREFIX1" "$PREFIX2" "$LOGS"
}

if ! chown_paths 2>/dev/null; then
  echo "Prefix directories need root ownership fix for container UID $CONTAINER_UID."
  if sudo chown -R "$CONTAINER_UID:$CONTAINER_GID" "$PREFIX1" "$PREFIX2" "$LOGS"; then
    echo "Applied ownership with sudo."
  else
    echo "Failed to chown prefix directories to $CONTAINER_UID:$CONTAINER_GID"
    echo "Run manually:"
    echo "  sudo chown -R $CONTAINER_UID:$CONTAINER_GID $PROJECT_ROOT/prefixes $LOGS"
    exit 1
  fi
fi

chmod -R u+rwX,g+rwX "$PREFIX1" "$PREFIX2" "$LOGS"

for dir in "$PREFIX1" "$PREFIX2"; do
  owner="$(stat -c '%u' "$dir" 2>/dev/null || stat -f '%u' "$dir")"
  if [ "$owner" != "$CONTAINER_UID" ]; then
    echo "Ownership check failed for $dir (owner=$owner, expected=$CONTAINER_UID)"
    exit 1
  fi
done

echo "Wine prefix permissions OK for UID $CONTAINER_UID."
