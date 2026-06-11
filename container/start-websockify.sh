#!/bin/sh
set -eu

if [ "${RA2_ENABLE_NOVNC_FALLBACK:-1}" = "0" ]; then
  printf '[websockify] disabled (RA2_ENABLE_NOVNC_FALLBACK=0)\n' >&2
  exit 0
fi

WEB_ROOT="/opt/novnc"
TOKEN_CFG="/opt/ra2/websockify-tokens.cfg"
RUNNER="/opt/novnc/utils/websockify/run"
LISTEN_PORT="${WEBSOCKIFY_PORT:-6080}"
TLS_CERT="${TLS_CERT:-/opt/ra2/tls/cert.pem}"
TLS_KEY="${TLS_KEY:-/opt/ra2/tls/key.pem}"

if [ -f "$TLS_CERT" ] && [ -f "$TLS_KEY" ]; then
  printf '[websockify] TLS enabled (%s)\n' "$TLS_CERT" >&2
  exec /bin/sh "$RUNNER" \
    --web="$WEB_ROOT" \
    --token-plugin TokenFile \
    --token-source="$TOKEN_CFG" \
    --cert="$TLS_CERT" \
    --key="$TLS_KEY" \
    "$LISTEN_PORT"
fi

printf '[websockify] WARNING: no TLS certificate at %s — noVNC is not in a secure context; expect crashes and missing audio/crypto features\n' "$TLS_CERT" >&2
exec /bin/sh /opt/novnc/utils/websockify/run \
  --web="$WEB_ROOT" \
  --token-plugin TokenFile \
  --token-source="$TOKEN_CFG" \
  "$LISTEN_PORT"
