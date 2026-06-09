#!/bin/sh
set -eu

HOST="${NAS_HOST:-MediaServer2Local}"
TARGET="${NAS_TARGET:-/volume2/Data/App_Development/ra2-lan-party/project}"
SOURCE="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"

echo "Syncing $SOURCE to $HOST:$TARGET"

cd "$SOURCE"
COPYFILE_DISABLE=1 tar czf - \
  --exclude='.DS_Store' \
  --exclude='._*' \
  --exclude='__pycache__' \
  --exclude='.git' \
  --exclude='.env' \
  . | ssh "$HOST" "mkdir -p '$TARGET' && tar xzf - -C '$TARGET'"

ssh "$HOST" "find '$TARGET' -name '._*' -delete 2>/dev/null || true; chmod +x '$TARGET'/scripts/*.sh '$TARGET'/container/entrypoint.sh 2>/dev/null || true"

echo "Sync complete."
