#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

PROJECT_ROOT="${PROJECT_ROOT:-/volume2/Data/App_Development/ra2-lan-party}"
COMPOSE_DIR="${COMPOSE_DIR:-$PROJECT_ROOT/project}"
MODE="${1:-launch}"

cd "$COMPOSE_DIR"

if [ ! -f compose.yaml ]; then
  echo "compose.yaml not found in $COMPOSE_DIR"
  exit 1
fi

sh "$SCRIPT_DIR/prepare-nas.sh"
sh "$SCRIPT_DIR/fix-prefix-perms.sh"

if [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env from .env.example — edit passwords and serials before exposing ports."
fi

case "$MODE" in
  prepare)
    sh "$SCRIPT_DIR/preflight-nas.sh"
    echo "Prepare complete. Add game assets, then run: sh scripts/bootstrap-nas.sh build"
    ;;
  build)
    sh "$SCRIPT_DIR/build-image-nas.sh"
    ;;
  launch)
    sh "$SCRIPT_DIR/validate-env.sh"
    sh "$SCRIPT_DIR/ingest-assets.sh"
    sh "$SCRIPT_DIR/ensure-tls.sh"
    run_compose .env up -d --build
    ;;
  status)
    run_compose .env ps
    ;;
  *)
    echo "Usage: $0 [prepare|build|launch|status]"
    exit 1
    ;;
esac
