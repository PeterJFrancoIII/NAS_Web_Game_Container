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

# Accept shared VNC_PASSWORD or legacy per-player keys during migration.
vnc_password="$(read_env_value VNC_PASSWORD "")"
if [ -z "$vnc_password" ]; then
  legacy1="$(read_env_value PLAYER1_VNC_PASSWORD "")"
  legacy2="$(read_env_value PLAYER2_VNC_PASSWORD "")"
  if [ -n "$legacy1" ] && [ "$legacy1" = "$legacy2" ] && [ "$legacy1" != "change-player1" ] && [ "$legacy1" != "change-player2" ]; then
    echo "[OK] VNC_PASSWORD derived from legacy PLAYER1/2_VNC_PASSWORD"
    vnc_password="$legacy1"
  elif [ -n "$legacy1" ] || [ -n "$legacy2" ]; then
    echo "[FAIL] set VNC_PASSWORD once for both players (legacy PLAYER1/2_VNC_PASSWORD differ)"
    fail=1
  else
    echo "[FAIL] VNC_PASSWORD is required"
    fail=1
  fi
else
  check_not_default VNC_PASSWORD change-me
fi

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

project_root="$(read_env_value PROJECT_ROOT "/volume2/Data/App_Development/ra2-lan-party")"
case "$project_root" in
  /volume2/Data/App_Development/ra2-lan-party|/Data/App_Development/ra2-lan-party)
    echo "[OK] PROJECT_ROOT=$project_root"
    ;;
  *)
    echo "[FAIL] PROJECT_ROOT must be under Data/App_Development/ra2-lan-party (got $project_root)"
    fail=1
    ;;
esac

path_under_root() {
  key="$1"
  value="$(read_env_value "$key" "")"
  [ -n "$value" ] || return 0
  case "$value" in
    "$project_root"/*)
      echo "[OK] $key under PROJECT_ROOT"
      ;;
    *)
      echo "[FAIL] $key must be under $project_root (got $value)"
      fail=1
      ;;
  esac
}

for key in ASSETS_DIR PREFIX1_DIR PREFIX2_DIR LOGS_DIR TLS_DIR DODI_INSTALLER_DIR; do
  path_under_root "$key"
done

assets_dir="$(read_env_value ASSETS_DIR "")"
case "$assets_dir" in
  "$project_root/assets"|"$project_root/assets-game1"|"$project_root/assets-game2")
    echo "[OK] ASSETS_DIR is a known game tree"
    ;;
  "$project_root"/*)
    echo "[WARN] ASSETS_DIR is under PROJECT_ROOT but not a known game tree: $assets_dir"
    ;;
esac

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "Environment validation passed."
