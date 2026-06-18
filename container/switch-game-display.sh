#!/bin/sh
# Switch the ultra stream display (Xvfb + display.env) before a game session starts.
set -eu

TARGET="${1:-}"
if [ -z "$TARGET" ] || ! printf '%s' "$TARGET" | grep -Eq '^[0-9]+x[0-9]+$'; then
  w="${GAME_SESSION_WIDTH:-}"
  h="${GAME_SESSION_HEIGHT:-}"
  if [ -n "$w" ] && [ -n "$h" ]; then
    TARGET="${w}x${h}"
  else
    TARGET="${RESOLUTION:-1024x768}"
  fi
fi

DISPLAY_ENV="${ULTRA_DISPLAY_ENV:-/home/commander/.ra2/display.env}"
DISPLAY_REVISION="${ULTRA_DISPLAY_REVISION:-/home/commander/.ra2/display-revision}"
DEPTH="${RA2_DISPLAY_DEPTH:-16}"
DISPLAY_TARGET="${DISPLAY:-:1}"
SUPERVISOR_CONFIG="${ULTRA_SUPERVISOR_CONFIG:-/opt/ra2/supervisord.conf}"

log() {
  printf '[ultra-display] %s\n' "$*" >&2
}

read_display_dims() {
  xdpyinfo -display "$DISPLAY_TARGET" 2>/dev/null | awk '/dimensions:/{print $2; exit}'
}

wait_for_xvfb() {
  i=0
  while [ "$i" -lt 45 ]; do
    if [ "$(read_display_dims)" = "$TARGET" ]; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

ctl() {
  supervisorctl -c "$SUPERVISOR_CONFIG" "$@"
}

if ! ctl status >/dev/null 2>&1; then
  log "supervisorctl unavailable; cannot switch display"
  exit 1
fi

current="$(read_display_dims || true)"

mkdir -p "$(dirname "$DISPLAY_ENV")" "$(dirname "$DISPLAY_REVISION")"
printf 'RESOLUTION=%s\nRA2_DISPLAY_DEPTH=%s\n' "$TARGET" "$DEPTH" >"$DISPLAY_ENV"
export RESOLUTION="$TARGET" RA2_DISPLAY_DEPTH="$DEPTH" DISPLAY="$DISPLAY_TARGET"

if [ "$current" = "$TARGET" ]; then
  date +%s >"$DISPLAY_REVISION"
  log "display already ${TARGET}; refreshed stream transport revision"
  exit 0
fi

log "switching stream display ${current:-unknown} -> ${TARGET}x${DEPTH}"

wineserver -k >/dev/null 2>&1 || true
sleep 1

ctl stop openbox xvfb || true
if [ -x /opt/ra2/cleanup-xvfb-display.sh ]; then
  /bin/sh /opt/ra2/cleanup-xvfb-display.sh "${DISPLAY_TARGET#:}"
fi
sleep 1

ctl start xvfb || exit 1
if ! wait_for_xvfb; then
  actual="$(read_display_dims || true)"
  log "Xvfb did not reach ${TARGET} (got ${actual:-unknown})"
  exit 1
fi

ctl start openbox || exit 1

if [ -x /opt/ra2/configure-display-modes.sh ]; then
  /bin/sh /opt/ra2/configure-display-modes.sh || log "RandR mode registration skipped"
fi

date +%s >"$DISPLAY_REVISION"
log "stream display ready at ${TARGET}"
