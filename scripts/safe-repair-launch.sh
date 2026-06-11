#!/bin/sh
# Safe staged RA2 repair/launch for DSM. Run on the NAS with sudo:
#   sudo sh scripts/safe-repair-launch.sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

COMPOSE_DIR="${COMPOSE_DIR:-/volume2/Data/App_Development/ra2-lan-party/project}"
HOLD_CONTAINERS="${HOLD_CONTAINERS:-gluetun ra2-player-1 ra2-player-2}"
LAUNCH_PLAYER2="${LAUNCH_PLAYER2:-1}"
BUILD_ON_NAS="${RA2_SAFE_BUILD:-0}"
ENABLE_WEBRTC="${RA2_SAFE_WEBRTC:-1}"

cd "$COMPOSE_DIR"

docker_try() {
  run_docker timeout 15 "$@"
}

echo "=== safe repair launch $(date) ==="
echo "host load: $(uptime)"

if [ "$(id -u)" -ne 0 ] && ! sudo -n true >/dev/null 2>&1; then
  echo "Run with sudo so Docker and synopkg are accessible."
  exit 1
fi

echo "=== start Container Manager if needed ==="
if command -v /usr/syno/bin/synopkg >/dev/null 2>&1; then
  /usr/syno/bin/synopkg start ContainerManager 2>/dev/null || true
fi

for i in $(seq 1 30); do
  if docker_try info >/dev/null 2>&1; then
    echo "docker ready after $i attempt(s)"
    break
  fi
  echo "waiting for docker ($i)..."
  sleep 5
done

if ! docker_try info >/dev/null 2>&1; then
  echo "Docker daemon is not reachable; aborting."
  exit 1
fi

echo "=== hold risky containers ==="
for c in $HOLD_CONTAINERS; do
  if docker_try inspect "$c" >/dev/null 2>&1; then
    echo "holding $c"
    docker_try update --restart=no "$c" 2>/dev/null || true
    docker_try stop -t 5 "$c" 2>/dev/null || true
  fi
done

docker_try compose --env-file .env -f compose.yaml down --remove-orphans 2>/dev/null || true

echo "=== prep ==="
sh "$SCRIPT_DIR/validate-env.sh"
sh "$SCRIPT_DIR/ingest-assets.sh"
sh "$SCRIPT_DIR/ensure-tls.sh"

export RA2_COMPOSE_TRANSCODE=0
export RA2_COMPOSE_WEBRTC="$ENABLE_WEBRTC"

if [ "$BUILD_ON_NAS" = "1" ]; then
  compose_action="up -d --build"
  echo "=== build mode enabled (RA2_SAFE_BUILD=1) ==="
else
  compose_action="up -d --no-build --force-recreate"
  echo "=== no-build mode (set RA2_SAFE_BUILD=1 only during off-peak maintenance) ==="
fi

echo "=== launch player 1 ==="
run_compose .env $compose_action ra2-player-1
sleep 20
docker_try ps -a --filter name=ra2-player-1 --format '{{.Names}} | {{.Status}}'

if [ "$LAUNCH_PLAYER2" = "1" ]; then
  echo "=== launch player 2 ==="
  run_compose .env $compose_action ra2-player-2
  sleep 20
  docker_try ps -a --filter name=ra2-player --format '{{.Names}} | {{.Status}}'
fi

echo "=== verify ==="
sh "$SCRIPT_DIR/verify-deployment.sh"
echo "=== safe repair launch complete ==="
