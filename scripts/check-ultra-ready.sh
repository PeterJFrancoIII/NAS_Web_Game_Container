#!/bin/sh
# Readiness checks for ultra-light browser streaming profile.
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

ENV_FILE="${ENV_FILE:-.env}"
SERVICE="${RA2_ULTRA_SERVICE:-ra2-player-1}"
WARN_ONLY="${RA2_ULTRA_WARN_ONLY:-0}"

section() {
  printf '\n== %s ==\n' "$1"
}

fail_or_warn() {
  if [ "$WARN_ONLY" = "1" ]; then
    printf 'WARN: %s\n' "$1"
  else
    printf 'FAIL: %s\n' "$1"
    exit 1
  fi
}

section "Ultra profile enabled"
if [ "${RA2_COMPOSE_ULTRA:-0}" != "1" ]; then
  fail_or_warn "RA2_COMPOSE_ULTRA is not enabled in ${ENV_FILE}"
fi

section "Container ${SERVICE}"
status="$(container_status "$SERVICE")"
if [ "$status" != "running" ]; then
  fail_or_warn "${SERVICE} is not running (status=${status:-missing})"
fi

section "Ultra runtime processes"
run_docker exec "$SERVICE" sh -lc '
  set -eu
  pgrep -af "Xvfb :1" || { echo "missing Xvfb"; exit 1; }
  pgrep -af ra2-stream-gateway.py || { echo "missing stream gateway"; exit 1; }
  pgrep -af stream-helper && echo "WARN: stream-helper running without client" || true
  pgrep -af websockify && { echo "websockify should not run in ultra mode"; exit 1; } || true
  pgrep -af x11vnc && { echo "x11vnc should not run in ultra mode"; exit 1; } || true
  echo "process check ok"
'

section "VAAPI / DRI"
run_docker exec "$SERVICE" sh -lc '
  test -e /dev/dri/renderD128 || { echo "missing renderD128"; exit 1; }
  gst-inspect-1.0 vah264enc >/dev/null 2>&1 || gst-inspect-1.0 vaapih264enc >/dev/null 2>&1 || {
    echo "no hardware H264 encoder plugin"
    exit 1
  }
  echo "encoder plugins ok"
'

section "Gateway HTTP"
run_docker exec "$SERVICE" sh -lc '
  PORT="${ULTRA_GATEWAY_PORT:-6080}"
  TLS_CERT="${TLS_CERT:-/opt/ra2/tls/cert.pem}"
  if [ -f "$TLS_CERT" ]; then
    curl -fsSk "https://127.0.0.1:${PORT}/" | head -c 200 | grep -q "RA2 Ultra" || exit 1
  else
    curl -fsS "http://127.0.0.1:${PORT}/" | head -c 200 | grep -q "RA2 Ultra" || exit 1
  fi
  echo "gateway page ok"
'

section "Stream settings"
run_docker exec "$SERVICE" sh -lc 'env | grep -E "^ULTRA_VIDEO_|^ULTRA_GATEWAY_|^ULTRA_AUDIO_" | sort'

section "Memory"
run_docker stats --no-stream "$SERVICE" 2>/dev/null || true

printf '\nUltra profile checks complete.'
case "$SERVICE" in
  ra2-player-2)
    port="$(read_env_value PLAYER2_HTTP_PORT 6082 "$ENV_FILE")"
    printf ' Open https://<NAS>:%s/ in Chromium.\n' "$port"
    ;;
  *)
    port="$(read_env_value PLAYER1_HTTP_PORT 6081 "$ENV_FILE")"
    printf ' Open https://<NAS>:%s/ in Chromium.\n' "$port"
    ;;
esac
printf 'See docs/ULTRA_LIGHT_ARCH_STREAMING.md\n'
