#!/bin/sh
set -eu

PORT="${ULTRA_GATEWAY_PORT:-6080}"
TLS_CERT="${TLS_CERT:-/opt/ra2/tls/cert.pem}"
TLS_KEY="${TLS_KEY:-/opt/ra2/tls/key.pem}"

if [ -f "$TLS_CERT" ] && [ -f "$TLS_KEY" ]; then
  if ! curl -fsSk "https://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
    exit 1
  fi
else
  if ! curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
    exit 1
  fi
fi

pgrep -f "Xvfb :1" >/dev/null || exit 1
pgrep -f "ra2-stream-gateway.py" >/dev/null || exit 1

GAME_PROCESS="${ULTRA_GAME_PROCESS:-gamemd.exe}"
if ps -eo stat=,comm= 2>/dev/null | awk -v name="$GAME_PROCESS" '$2 == name && $1 ~ /^Z/ { found=1 } END { exit found ? 0 : 1 }'; then
  exit 1
fi
if ! ps -eo stat=,comm= 2>/dev/null | awk -v name="$GAME_PROCESS" '$2 == name && $1 !~ /^Z/ { found=1 } END { exit found ? 0 : 1 }'; then
  exit 1
fi

exit 0
