#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

COMPOSE_DIR="${COMPOSE_DIR:-/volume2/Data/App_Development/ra2-lan-party/project}"
ENV_FILE="${ENV_FILE:-$COMPOSE_DIR/.env}"

if [ "$(id -u)" -ne 0 ]; then
  echo "This script needs Synology Docker admin access."
  echo "Run: sudo sh scripts/apply-serial-fix.sh"
  exit 1
fi

cd "$COMPOSE_DIR"

serial1="$(read_env_value PLAYER1_SERIAL "" "$ENV_FILE")"
serial2="$(read_env_value PLAYER2_SERIAL "" "$ENV_FILE")"
if [ -z "$serial1" ] || [ -z "$serial2" ]; then
  echo "[FAIL] PLAYER1_SERIAL and PLAYER2_SERIAL must both be set in $ENV_FILE"
  exit 1
fi
if [ "$serial1" = "$serial2" ]; then
  echo "[FAIL] PLAYER1_SERIAL and PLAYER2_SERIAL must differ"
  exit 1
fi

echo "Recreating RA2 players so entrypoint writes Yuri's Revenge serial keys..."
run_compose "$ENV_FILE" up -d --force-recreate

echo
echo "Waiting for startup..."
sleep 20
run_docker ps -a --filter name=ra2-player --format 'table {{.Names}}\t{{.Status}}'

echo
echo "Checking Westwood serial registry keys..."
for container in ra2-player-1 ra2-player-2; do
  echo "== $container =="
  run_docker exec "$container" sh -lc '
    for key in \
      "HKLM\\Software\\WOW6432Node\\Westwood\\Red Alert 2" \
      "HKLM\\Software\\WOW6432Node\\Westwood\\Yuri'\''s Revenge"; do
      printf "%s: " "$key"
      wine reg query "$key" /v Serial 2>/dev/null | awk "/Serial/ {print \$3; found=1} END {if (!found) print \"missing\"}"
    done
  ' || true
done

echo
echo "Done. Reconnect both noVNC sessions and retry LAN join."
