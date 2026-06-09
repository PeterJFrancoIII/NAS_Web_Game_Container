#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

PROJECT_ROOT="${PROJECT_ROOT:-/volume2/Data/App_Development/ra2-lan-party}"
COMPOSE_DIR="${COMPOSE_DIR:-$PROJECT_ROOT/project}"
COMPOSE_FILES="-f compose.yaml -f compose.https.yaml -f compose.transcode.yaml"

if [ "$(id -u)" -ne 0 ]; then
  echo "This script needs Synology Docker admin access."
  echo "Run: sudo sh scripts/admin-rebuild-check.sh"
  exit 1
fi

cd "$COMPOSE_DIR"

if [ ! -f .env ]; then
  echo ".env not found in $COMPOSE_DIR"
  exit 1
fi

echo "== Reset Wine prefixes =="
sh "$SCRIPT_DIR/reset-wine-prefixes.sh"

echo
echo "== Build and start RA2 players =="
run_docker compose --env-file .env $COMPOSE_FILES up -d --build

echo
echo "== Wait for container startup =="
sleep 45
run_docker ps -a --filter name=ra2-player --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

echo
echo "== Player 1 recent logs =="
run_docker logs --tail=80 ra2-player-1 || true

echo
echo "== Player 2 recent logs =="
run_docker logs --tail=40 ra2-player-2 || true

echo
echo "== Wine version =="
run_docker exec ra2-player-1 sh -lc '/opt/wine/bin/wine --version' || true

echo
echo "== Deployment verification =="
sh "$SCRIPT_DIR/verify-deployment.sh" || true

echo
echo "== Browser URLs =="
echo "Player 1: http://192.168.0.193:6081/vnc.html"
echo "Player 2: http://192.168.0.193:6082/vnc.html"
