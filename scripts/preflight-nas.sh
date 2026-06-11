#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

PROJECT_ROOT="${PROJECT_ROOT:-/volume2/Data/App_Development/ra2-lan-party}"
COMPOSE_DIR="${COMPOSE_DIR:-$PROJECT_ROOT/project}"
ASSETS_DIR="${ASSETS_DIR:-$PROJECT_ROOT/assets}"

cd "$COMPOSE_DIR"
GAME_EXE="$(read_env_value GAME_EXE RA2MD.exe .env)"
PREFIX1_DIR="$(read_env_value PREFIX1_DIR "$PROJECT_ROOT/prefixes/player1-win32" .env)"
PREFIX2_DIR="$(read_env_value PREFIX2_DIR "$PROJECT_ROOT/prefixes/player2-win32" .env)"

pass=0
warn=0
fail=0

ok() {
  printf '[OK] %s\n' "$1"
  pass=$((pass + 1))
}

note() {
  printf '[WARN] %s\n' "$1"
  warn=$((warn + 1))
}

bad() {
  printf '[FAIL] %s\n' "$1"
  fail=$((fail + 1))
}

printf 'RA2 LAN party preflight\n'
printf 'Project root: %s\n\n' "$PROJECT_ROOT"

for dir in "$PROJECT_ROOT" "$COMPOSE_DIR" "$ASSETS_DIR" "$PREFIX1_DIR" "$PREFIX2_DIR"; do
  if [ -d "$dir" ]; then
    ok "Directory exists: $dir"
  else
    bad "Missing directory: $dir"
  fi
done

for file in "$COMPOSE_DIR/compose.yaml" "$COMPOSE_DIR/container/Dockerfile" "$COMPOSE_DIR/.env"; do
  if [ -f "$file" ]; then
    ok "File exists: $file"
  else
    bad "Missing file: $file"
  fi
done

for template in ddraw.ini RA2.ini RA2MD.ini ipxwrapper.ini; do
  if [ -f "$ASSETS_DIR/$template" ]; then
    ok "Config template present: $template"
  else
    note "Config template missing: $template"
  fi
done

for required in "$GAME_EXE" ddraw.dll ddraw.ini wsock32.dll; do
  if [ -f "$ASSETS_DIR/$required" ]; then
    ok "Game asset present: $required"
  else
    note "Game asset pending: $required"
  fi
done

if [ -f "$ASSETS_DIR/ddraw.dll" ]; then
  if grep -aq "cnc-ddraw" "$ASSETS_DIR/ddraw.dll" 2>/dev/null; then
    ok "ddraw.dll is cnc-ddraw"
  else
    bad "ddraw.dll is not cnc-ddraw (run: sh scripts/install-cnc-ddraw.sh)"
  fi
fi

if command -v "$DOCKER" >/dev/null 2>&1; then
  ok "Docker CLI found: $DOCKER"
else
  bad "Docker CLI not found"
fi

if "$DOCKER" info >/dev/null 2>&1; then
  ok "Docker daemon reachable for current user"
elif sudo -n "$DOCKER" info >/dev/null 2>&1; then
  ok "Docker daemon reachable via passwordless sudo"
else
  note "Docker daemon not reachable — use sudo or Container Manager"
fi

if "$DOCKER" compose version >/dev/null 2>&1 || sudo -n "$DOCKER" compose version >/dev/null 2>&1; then
  ok "Docker Compose plugin available"
else
  bad "Docker Compose plugin unavailable"
fi

port1="$(read_env_value PLAYER1_HTTP_PORT 6081 .env)"
port2="$(read_env_value PLAYER2_HTTP_PORT 6082 .env)"
if [ "$port1" = "8080" ] || [ "$port2" = "8080" ]; then
  bad "Ports 6081/6082 must not use 8080 (qBittorrent/Gluetun on this NAS)"
else
  ok "Browser ports configured: $port1 and $port2"
fi

if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
  ok "Python available for contract tests"
else
  note "Python not available for contract tests"
fi

if [ -f "$COMPOSE_DIR/compose.https.yaml" ]; then
  ok "HTTPS compose overlay present"
else
  note "HTTPS compose overlay missing"
fi

if tls_material_present "$COMPOSE_DIR/.env"; then
  if tls_key_usable_by_container "$COMPOSE_DIR/.env"; then
    ok "TLS certificate ready for container uid 1000"
  else
    bad "TLS key exists but is not readable by container uid 1000 — run: sh scripts/ensure-tls.sh"
  fi
else
  note "TLS not generated yet — run: sh scripts/ensure-tls.sh before browser play"
fi

printf '\nSummary: %s passed, %s warnings, %s failed\n' "$pass" "$warn" "$fail"

if [ "$fail" -gt 0 ]; then
  exit 1
fi

exit 0
