#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

COMPOSE_DIR="${COMPOSE_DIR:-/volume2/Data/App_Development/ra2-lan-party/project}"

cd "$COMPOSE_DIR"

if [ ! -f compose.yaml ]; then
  echo "compose.yaml not found in $COMPOSE_DIR"
  exit 1
fi

if [ ! -f .env ]; then
  cp .env.example .env
fi

echo "Building RA2 runtime image (no game files required)..."
run_docker compose --env-file .env build
echo "Image build complete."
