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
pgrep -f "start-game-ultra.sh" >/dev/null || pgrep -f "run-game-session.sh" >/dev/null || exit 1

# Reject zombie game processes from any supported title.
for proc in gamemd.exe EMPIRES2.EXE; do
  if ps -eo stat=,comm= 2>/dev/null | awk -v name="$proc" '$2 == name && $1 ~ /^Z/ { found=1 } END { exit found ? 0 : 1 }'; then
    exit 1
  fi
done

exit 0
