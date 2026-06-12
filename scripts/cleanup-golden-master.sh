#!/bin/sh
# Prune stale RA2 Docker artifacts after golden-master lock-in.
# Run on the NAS with sudo:
#   sudo sh scripts/cleanup-golden-master.sh
#   sudo sh scripts/cleanup-golden-master.sh --remove-latest-image
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

REMOVE_LATEST=0
if [ "${1:-}" = "--remove-latest-image" ]; then
  REMOVE_LATEST=1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo sh scripts/cleanup-golden-master.sh"
  exit 1
fi

echo "[cleanup] stopped RA2 containers (excluding running production players)"
run_docker ps -a --filter name=ra2-player --filter status=exited --format '{{.Names}}' 2>/dev/null | while read -r name; do
  [ -n "$name" ] || continue
  case "$name" in
    ra2-player-1|ra2-player-2) continue ;;
  esac
  echo "[cleanup] removing $name"
  run_docker rm "$name" 2>/dev/null || true
done

run_docker ps -a --filter name=project-ra2-player --filter status=exited --format '{{.Names}}' 2>/dev/null | while read -r name; do
  [ -n "$name" ] || continue
  echo "[cleanup] removing legacy $name"
  run_docker rm "$name" 2>/dev/null || true
done

echo "[cleanup] dangling images"
run_docker image prune -f 2>/dev/null || true

if [ "$REMOVE_LATEST" = "1" ]; then
  if run_docker image inspect ra2-lan-party:latest >/dev/null 2>&1; then
    if run_docker image inspect ra2-lan-party:ultra >/dev/null 2>&1; then
      echo "[cleanup] removing ra2-lan-party:latest (ultra is production)"
      run_docker rmi ra2-lan-party:latest 2>/dev/null || true
    else
      echo "[cleanup] skip latest removal — ra2-lan-party:ultra not present"
    fi
  fi
fi

echo "[cleanup] current RA2 images:"
run_docker images 'ra2-lan-party*' --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}' 2>/dev/null || true

echo "[cleanup] running players:"
run_docker ps --filter name=ra2-player-1 --filter name=ra2-player-2 --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null || true

echo "[cleanup] done"
