#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}"

cd "$COMPOSE_DIR"

if [ ! -f .env ]; then
  echo "Missing .env — copy from .env.example first."
  exit 1
fi

. "$SCRIPT_DIR/lib.sh"

fail=0

check_not_default() {
  key="$1"
  bad_value="$2"
  value="$(read_env_value "$key" "")"
  if [ "$value" = "$bad_value" ]; then
    echo "[FAIL] $key is still the placeholder value"
    fail=1
  else
    echo "[OK] $key customized"
  fi
}

check_not_default PLAYER1_VNC_PASSWORD change-player1
check_not_default PLAYER2_VNC_PASSWORD change-player2
check_not_default PLAYER1_SERIAL 11112222333344445555
check_not_default PLAYER2_SERIAL 55554444333322221111

serial1="$(read_env_value PLAYER1_SERIAL "")"
serial2="$(read_env_value PLAYER2_SERIAL "")"
if [ -z "$serial1" ] || [ -z "$serial2" ]; then
  echo "[FAIL] PLAYER1_SERIAL and PLAYER2_SERIAL must be set"
  fail=1
elif [ "$serial1" = "$serial2" ]; then
  echo "[FAIL] PLAYER1_SERIAL and PLAYER2_SERIAL must differ"
  fail=1
else
  echo "[OK] unique player serials configured"
fi

for port in PLAYER1_HTTP_PORT PLAYER2_HTTP_PORT; do
  value="$(read_env_value "$port" "")"
  case "$value" in
    ''|*[!0-9]*)
      echo "[FAIL] $port must be a numeric port"
      fail=1
      ;;
    8080)
      echo "[FAIL] $port must not be 8080 (used by qBittorrent/Gluetun on this NAS)"
      fail=1
      ;;
    *)
      echo "[OK] $port=$value"
      ;;
  esac
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "Environment validation passed."
