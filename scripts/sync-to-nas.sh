#!/bin/sh
set -eu

HOST="${NAS_HOST:-MediaServer2Local}"
TARGET="${NAS_TARGET:-/volume2/Data/App_Development/ra2-lan-party/project}"
SOURCE="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"

echo "Syncing $SOURCE to $HOST:$TARGET"

cd "$SOURCE"
TAR_REMOTE="mkdir -p '$TARGET' && tar xzf - -C '$TARGET'"
CHMOD_REMOTE="find '$TARGET' -name '._*' -delete 2>/dev/null || true; chmod +x '$TARGET'/scripts/*.sh '$TARGET'/container/entrypoint.sh 2>/dev/null || true"
if ! ssh "$HOST" "test -d '$TARGET' && test -w '$TARGET'" 2>/dev/null; then
  TAR_REMOTE="sudo mkdir -p '$TARGET' && sudo tar xzf - -C '$TARGET'"
  CHMOD_REMOTE="sudo find '$TARGET' -name '._*' -delete 2>/dev/null || true; sudo chmod +x '$TARGET'/scripts/*.sh '$TARGET'/container/entrypoint.sh 2>/dev/null || true"
fi

COPYFILE_DISABLE=1 tar czf - \
  --exclude='.DS_Store' \
  --exclude='._*' \
  --exclude='__pycache__' \
  --exclude='.git' \
  --exclude='.env' \
  . | ssh "$HOST" "$TAR_REMOTE"

ssh "$HOST" "$CHMOD_REMOTE"

echo "Sync complete."
echo ""
echo "RAM debug loop (recommended — hot path in /dev/shm, port 6091):"
echo "  NAS_HOST=${HOST} sh scripts/sync-to-ram.sh"
echo ""
echo "Production player (disk bind mounts, port 6081):"
echo "  NAS_HOST=${HOST} sh scripts/redeploy-ultra.sh"
