#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

COMPOSE_DIR="${COMPOSE_DIR:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}"
ENV_FILE="${ENV_FILE:-$COMPOSE_DIR/.env}"

cd "$COMPOSE_DIR"

if ! tls_material_present "$ENV_FILE"; then
  sh "$SCRIPT_DIR/generate-tls-certs.sh"
fi

fix_tls_permissions "$ENV_FILE"

if ! tls_key_usable_by_container "$ENV_FILE"; then
  echo "[FAIL] TLS key is not readable by container user uid 1000: $(tls_key_path "$ENV_FILE")"
  echo "       Run: sudo chown 1000:1000 $(tls_dir_from_env "$ENV_FILE")/*.pem"
  exit 1
fi

echo "[OK] TLS material ready at $(tls_dir_from_env "$ENV_FILE")"
